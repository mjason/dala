import React from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { fireEvent, render, screen, waitFor } from "@testing-library/react";
import { I18nProvider } from "./i18n";

const listDirectory = vi.fn();
const readFile = vi.fn();
const writeFile = vi.fn();

vi.mock("../ash_rpc", () => ({
  buildCSRFHeaders: () => ({}),
  listDirectory: (...args: unknown[]) => listDirectory(...args),
  readFile: (...args: unknown[]) => readFile(...args),
  writeFile: (...args: unknown[]) => writeFile(...args),
}));

import FileDrawer from "./FileDrawer";

function listing(path: string, entries: object[], parent: string | null = "/") {
  return { success: true, data: { path, parent, entries } };
}

const entry = (name: string, type: string, size = 10) => ({
  name,
  type,
  symlink: false,
  size,
  mtime: null,
});

function renderDrawer(overrides: Partial<React.ComponentProps<typeof FileDrawer>> = {}) {
  const props = {
    path: "/proj",
    followCwd: true,
    onNavigate: vi.fn(),
    onToggleFollow: vi.fn(),
    onClose: vi.fn(),
    onError: vi.fn(),
    ...overrides,
  };
  render(
    <I18nProvider>
      <FileDrawer {...props} />
    </I18nProvider>,
  );
  return props;
}

beforeEach(() => {
  listDirectory.mockReset();
  readFile.mockReset();
  writeFile.mockReset();
});

describe("FileDrawer tree", () => {
  it("renders the root listing", async () => {
    listDirectory.mockResolvedValueOnce(
      listing("/proj", [entry("src", "directory"), entry("mix.exs", "file", 1234)]),
    );

    renderDrawer();

    expect(await screen.findByText("src")).toBeInTheDocument();
    expect(screen.getByText("mix.exs")).toBeInTheDocument();
    expect(screen.getByText("1.2 KB")).toBeInTheDocument();
  });

  it("expands a directory in place and collapses it again", async () => {
    listDirectory
      .mockResolvedValueOnce(listing("/proj", [entry("src", "directory")]))
      .mockResolvedValueOnce(listing("/proj/src", [entry("main.ex", "file")], "/proj"));

    renderDrawer();

    fireEvent.click(await screen.findByText("src"));
    expect(await screen.findByText("main.ex")).toBeInTheDocument();
    expect(listDirectory).toHaveBeenLastCalledWith(
      expect.objectContaining({ input: { path: "/proj/src" } }),
    );

    // collapse: children disappear, no extra fetch
    fireEvent.click(screen.getByText("src"));
    expect(screen.queryByText("main.ex")).not.toBeInTheDocument();
    expect(listDirectory).toHaveBeenCalledTimes(2);

    // re-expand uses the cache
    fireEvent.click(screen.getByText("src"));
    expect(await screen.findByText("main.ex")).toBeInTheDocument();
    expect(listDirectory).toHaveBeenCalledTimes(2);
  });

  it("hides dotfiles until toggled", async () => {
    listDirectory.mockResolvedValueOnce(
      listing("/proj", [entry(".env", "file"), entry("app.ex", "file")]),
    );

    renderDrawer();

    expect(await screen.findByText("app.ex")).toBeInTheDocument();
    expect(screen.queryByText(".env")).not.toBeInTheDocument();
    expect(screen.getByText(/1 hidden/)).toBeInTheDocument();

    fireEvent.click(screen.getByTitle(".hidden"));
    expect(await screen.findByText(".env")).toBeInTheDocument();
  });

  it("navigates up via ..", async () => {
    listDirectory.mockResolvedValueOnce(listing("/proj", [entry("src", "directory")], "/"));

    const props = renderDrawer();

    fireEvent.click(await screen.findByText(".."));
    expect(props.onNavigate).toHaveBeenCalledWith("/");
  });

  it("opens a JSON preview formatted", async () => {
    listDirectory.mockResolvedValueOnce(listing("/proj", [entry("cfg.json", "file")]));
    readFile.mockResolvedValueOnce({
      success: true,
      data: {
        path: "/proj/cfg.json",
        size: 20,
        truncated: false,
        binary: false,
        content: '{"a":1}',
      },
    });

    renderDrawer();

    fireEvent.click(await screen.findByText("cfg.json"));
    await waitFor(() => {
      const preview = document.getElementById("file-preview");
      expect(preview?.textContent).toContain('"a": 1');
    });
  });

  it("opens a CSV preview as a table", async () => {
    listDirectory.mockResolvedValueOnce(listing("/proj", [entry("data.csv", "file")]));
    readFile.mockResolvedValueOnce({
      success: true,
      data: {
        path: "/proj/data.csv",
        size: 30,
        truncated: false,
        binary: false,
        content: "name,age\nAda,36\nAlan,41\n",
      },
    });

    renderDrawer();

    fireEvent.click(await screen.findByText("data.csv"));
    expect(await screen.findByRole("table")).toBeInTheDocument();
    expect(screen.getByText("Ada")).toBeInTheDocument();
    expect(screen.getByText(/2 rows/)).toBeInTheDocument();
  });

  it("offers to open HTML files in the browser", async () => {
    listDirectory.mockResolvedValueOnce(listing("/proj", [entry("index.html", "file")]));
    readFile.mockResolvedValueOnce({
      success: true,
      data: {
        path: "/proj/index.html",
        size: 15,
        truncated: false,
        binary: false,
        content: "<h1>hello</h1>",
      },
    });

    renderDrawer();

    fireEvent.click(await screen.findByText("index.html"));
    const open = await screen.findByText("Open in browser");
    expect(open).toHaveAttribute("href", "/files/raw?path=%2Fproj%2Findex.html");
  });

  it("shows images via the raw endpoint without reading the file", async () => {
    listDirectory.mockResolvedValueOnce(listing("/proj", [entry("logo.png", "file")]));

    renderDrawer();

    fireEvent.click(await screen.findByText("logo.png"));
    const img = await screen.findByRole("img");
    expect(img).toHaveAttribute("src", "/files/raw?path=%2Fproj%2Flogo.png");
    expect(readFile).not.toHaveBeenCalled();
  });

  it("surfaces listing errors", async () => {
    listDirectory.mockResolvedValueOnce({
      success: false,
      errors: [{ message: "cannot list /proj: permission denied" }],
    });

    const props = renderDrawer();

    await waitFor(() =>
      expect(props.onError).toHaveBeenCalledWith("cannot list /proj: permission denied"),
    );
  });
});

describe("FilePreview wrapping", () => {
  it("wraps long lines by default and can toggle to horizontal scroll", async () => {
    listDirectory.mockResolvedValueOnce(listing("/proj", [entry("notes.txt", "file")]));
    readFile.mockResolvedValueOnce({
      success: true,
      data: {
        path: "/proj/notes.txt",
        size: 400,
        truncated: false,
        binary: false,
        content: "x".repeat(400),
      },
    });

    renderDrawer();

    fireEvent.click(await screen.findByText("notes.txt"));
    await screen.findByText("x".repeat(400));

    const pre = document.querySelector("#file-preview pre")!;
    expect(pre.className).toContain("whitespace-pre-wrap");

    fireEvent.click(document.getElementById("wrap-toggle-button")!);
    expect(document.querySelector("#file-preview pre")!.className).not.toContain(
      "whitespace-pre-wrap",
    );
  });
});

describe("FilePreview editing", () => {
  const openText = async (content: string, name = "notes.txt") => {
    listDirectory.mockResolvedValueOnce(listing("/proj", [entry(name, "file", 20)]));
    readFile.mockResolvedValueOnce({
      success: true,
      data: { path: `/proj/${name}`, size: content.length, truncated: false, binary: false, content },
    });
    const props = renderDrawer();
    fireEvent.click(await screen.findByText(name));
    await screen.findByText(content);
    return props;
  };

  it("edits and saves a file, updating the preview", async () => {
    await openText("hello world");
    // enter edit mode
    listDirectory.mockResolvedValue(listing("/proj", [entry("notes.txt", "file", 20)]));
    writeFile.mockResolvedValueOnce({ success: true, data: { path: "/proj/notes.txt", size: 5 } });

    fireEvent.click(document.getElementById("edit-file-button")!);
    const editor = document.getElementById("code-editor") as HTMLTextAreaElement;
    expect(editor).toBeInTheDocument();
    expect(editor.value).toBe("hello world");

    fireEvent.change(editor, { target: { value: "brave new world" } });

    const saveButton = document.getElementById("save-file-button") as HTMLButtonElement;
    expect(saveButton.disabled).toBe(false);
    fireEvent.click(saveButton);

    await waitFor(() =>
      expect(writeFile).toHaveBeenCalledWith(
        expect.objectContaining({ input: { path: "/proj/notes.txt", content: "brave new world" } }),
      ),
    );
    // back to view mode showing the new content
    await waitFor(() => expect(document.getElementById("code-editor")).toBeNull());
    expect(await screen.findByText("brave new world")).toBeInTheDocument();
  });

  it("disables save until the content changes", async () => {
    await openText("unchanged");
    fireEvent.click(document.getElementById("edit-file-button")!);
    expect((document.getElementById("save-file-button") as HTMLButtonElement).disabled).toBe(true);
  });

  it("surfaces save errors", async () => {
    const props = await openText("data");
    writeFile.mockResolvedValueOnce({ success: false, errors: [{ message: "cannot write: permission denied" }] });

    fireEvent.click(document.getElementById("edit-file-button")!);
    fireEvent.change(document.getElementById("code-editor")!, { target: { value: "changed" } });
    fireEvent.click(document.getElementById("save-file-button")!);

    await waitFor(() =>
      expect(props.onError).toHaveBeenCalledWith("cannot write: permission denied"),
    );
  });

  it("does not offer editing for truncated files", async () => {
    listDirectory.mockResolvedValueOnce(listing("/proj", [entry("big.log", "file", 9_000_000)]));
    readFile.mockResolvedValueOnce({
      success: true,
      data: { path: "/proj/big.log", size: 9_000_000, truncated: true, binary: false, content: "partial" },
    });
    renderDrawer();
    fireEvent.click(await screen.findByText("big.log"));
    await screen.findByText("partial");
    expect(document.getElementById("edit-file-button")).toBeNull();
  });
});
