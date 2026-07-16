import React from "react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { act, fireEvent, render, screen, waitFor } from "@testing-library/react";
import { EditorView } from "@codemirror/view";
import { I18nProvider } from "./i18n";

/** The CodeMirror view inside the editor host div. */
function editorView(): EditorView {
  const content = document.querySelector("#code-editor .cm-content");
  const view = content && EditorView.findFromDOM(content as HTMLElement);
  if (!view) throw new Error("editor view not found");
  return view;
}

function setEditorText(view: EditorView, text: string) {
  act(() => {
    view.dispatch({ changes: { from: 0, to: view.state.doc.length, insert: text } });
  });
}

const listDirectory = vi.fn();
const readFile = vi.fn();
const writeFile = vi.fn();
const deleteEntry = vi.fn();
const gitStatus = vi.fn();
const uploadMultipartFile = vi.fn();

vi.mock("../ash_rpc", () => ({
  buildCSRFHeaders: () => ({}),
  listDirectory: (...args: unknown[]) => listDirectory(...args),
  readFile: (...args: unknown[]) => readFile(...args),
  writeFile: (...args: unknown[]) => writeFile(...args),
  deleteEntry: (...args: unknown[]) => deleteEntry(...args),
  gitStatus: (...args: unknown[]) => gitStatus(...args),
}));

vi.mock("./fileUpload", async (importOriginal) => ({
  ...(await importOriginal<typeof import("./fileUpload")>()),
  uploadMultipartFile: (...args: unknown[]) => uploadMultipartFile(...args),
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
  deleteEntry.mockReset();
  gitStatus.mockReset();
  uploadMultipartFile.mockReset();
  uploadMultipartFile.mockResolvedValue({ path: "/uploaded/file", size: 1 });
  gitStatus.mockResolvedValue({
    success: true,
    data: { repo: false, root: null, branch: null, files: [] },
  });
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

  it("shows Git decorations without relying on native path tooltips", async () => {
    listDirectory.mockResolvedValueOnce(
      listing("/proj", [entry("src", "directory"), entry("mix.exs", "file", 1234)]),
    );
    gitStatus.mockResolvedValueOnce({
      success: true,
      data: {
        repo: true,
        root: "/proj",
        branch: "main",
        files: [
          { path: "mix.exs", status: " M", staged: false, unstaged: true },
          { path: "src/main.ex", status: "??", staged: false, unstaged: true },
        ],
      },
    });

    renderDrawer();

    const fileRow = (await screen.findByText("mix.exs")).closest("[data-path]")!;
    const folderRow = screen.getByText("src").closest("[data-path]")!;
    expect(fileRow).not.toHaveAttribute("title");
    const modified = fileRow.querySelector('[data-git-status="M"]');
    expect(modified).not.toBeNull();
    expect(modified).not.toHaveAttribute("title");
    expect(modified).toHaveClass("text-git-modified");
    expect(folderRow).not.toHaveAttribute("title");
    expect(folderRow.querySelector('[data-git-status="•"]')).not.toBeNull();
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

    const content = document.querySelector("#file-preview .cm-content")!;
    expect(content.className).toContain("cm-lineWrapping");

    fireEvent.click(document.getElementById("wrap-toggle-button")!);
    expect(document.querySelector("#file-preview .cm-content")!.className).not.toContain(
      "cm-lineWrapping",
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
    const view = editorView();
    expect(view.state.doc.toString()).toBe("hello world");

    setEditorText(view, "brave new world");

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
    setEditorText(editorView(), "changed");
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

describe("FileDrawer keyboard and delete", () => {
  const renderWithFiles = async () => {
    listDirectory.mockResolvedValueOnce(
      listing("/proj", [entry("src", "directory"), entry("a.txt", "file"), entry("b.txt", "file")]),
    );
    const props = renderDrawer();
    await screen.findByText("a.txt");
    return props;
  };

  const tree = () => document.getElementById("file-tree")!;

  it("navigates with arrows and opens with Enter", async () => {
    await renderWithFiles();
    readFile.mockResolvedValueOnce({
      success: true,
      data: { path: "/proj/a.txt", size: 5, truncated: false, binary: false, content: "hello" },
    });

    // up-row (parent "/") is first, then src, then a.txt
    fireEvent.keyDown(tree(), { key: "ArrowDown" });
    fireEvent.keyDown(tree(), { key: "ArrowDown" });
    fireEvent.keyDown(tree(), { key: "ArrowDown" });
    expect(document.querySelector('[data-path="/proj/a.txt"]')!.getAttribute("aria-selected")).toBe(
      "true",
    );

    fireEvent.keyDown(tree(), { key: "Enter" });
    await screen.findByText("hello");
    expect(readFile).toHaveBeenCalledWith(
      expect.objectContaining({ input: { path: "/proj/a.txt" } }),
    );
  });

  it("deletes an entry through the confirm modal", async () => {
    await renderWithFiles();
    deleteEntry.mockResolvedValueOnce({ success: true, data: { path: "/proj/b.txt" } });
    listDirectory.mockResolvedValueOnce(
      listing("/proj", [entry("src", "directory"), entry("a.txt", "file")]),
    );

    fireEvent.click(document.querySelector('[data-delete="/proj/b.txt"]')!);
    expect(document.getElementById("delete-entry-modal")).toBeInTheDocument();

    fireEvent.click(document.getElementById("confirm-delete-entry-button")!);
    await waitFor(() =>
      expect(deleteEntry).toHaveBeenCalledWith(
        expect.objectContaining({ input: { path: "/proj/b.txt" } }),
      ),
    );
    await waitFor(() => expect(screen.queryByText("b.txt")).toBeNull());
  });

  it("Delete key targets the selected row", async () => {
    await renderWithFiles();
    fireEvent.keyDown(tree(), { key: "ArrowDown" });
    fireEvent.keyDown(tree(), { key: "ArrowDown" });
    fireEvent.keyDown(tree(), { key: "ArrowDown" });
    fireEvent.keyDown(tree(), { key: "Delete" });
    expect(document.getElementById("delete-entry-modal")).toBeInTheDocument();
    // The dialog spells the path out in FULL (it used to be a truncated
    // single line with the path only in a title tooltip — you cannot confirm
    // a delete you cannot read).
    expect(document.getElementById("delete-target-path")).toHaveTextContent("/proj/a.txt");
  });

  it("download links point at the raw endpoint", async () => {
    await renderWithFiles();
    const link = document.querySelector('[data-download="/proj/a.txt"]') as HTMLAnchorElement;
    expect(link.href).toContain("/files/raw?");
    expect(link.href).toContain("download=1");
  });
});

describe("FileDrawer upload targeting", () => {
  const setup = async () => {
    listDirectory.mockResolvedValue(
      listing("/proj", [entry("src", "directory"), entry("a.txt", "file")]),
    );
    renderDrawer();
    await screen.findByText("a.txt");
    return uploadMultipartFile;
  };

  const pasteFile = () => {
    const file = new File(["x"], "pasted.txt", { type: "text/plain" });
    const clipboardData = {
      items: [{ kind: "file", getAsFile: () => file }],
      files: [file],
    };
    fireEvent.paste(document.getElementById("file-tree")!, { clipboardData });
  };

  it("pastes OS-copied files into the selected directory", async () => {
    const uploadMock = await setup();

    // Select the "src" directory (up-row first, then src).
    const tree = document.getElementById("file-tree")!;
    fireEvent.keyDown(tree, { key: "ArrowDown" });
    fireEvent.keyDown(tree, { key: "ArrowDown" });
    expect(document.querySelector('[data-path="/proj/src"]')!.getAttribute("aria-selected")).toBe(
      "true",
    );

    pasteFile();
    await waitFor(() => expect(uploadMock).toHaveBeenCalled());
    expect(uploadMock.mock.calls[0][0]).toMatchObject({ fields: { dir: "/proj/src" } });
  });

  it("pastes into the root when nothing is selected", async () => {
    const uploadMock = await setup();

    pasteFile();
    await waitFor(() => expect(uploadMock).toHaveBeenCalled());
    expect(uploadMock.mock.calls[0][0]).toMatchObject({ fields: { dir: "/proj" } });
  });

  it("a selected file targets its parent directory", async () => {
    const uploadMock = await setup();

    readFile.mockResolvedValueOnce({
      success: true,
      data: { path: "/proj/a.txt", size: 1, truncated: false, binary: false, content: "x" },
    });
    fireEvent.click(document.querySelector('[data-path="/proj/a.txt"]')!);

    pasteFile();
    await waitFor(() => expect(uploadMock).toHaveBeenCalled());
    expect(uploadMock.mock.calls[0][0]).toMatchObject({ fields: { dir: "/proj" } });
  });

  it("shows filename, byte progress and cancels the active upload", async () => {
    await setup();
    uploadMultipartFile.mockImplementationOnce(
      ({ onProgress, signal }: { onProgress: (loaded: number, total: number) => void; signal: AbortSignal }) =>
        new Promise((_resolve, reject) => {
          onProgress(5, 10);
          signal.addEventListener("abort", () => reject(new DOMException("cancelled", "AbortError")));
        }),
    );

    pasteFile();
    await waitFor(() => expect(screen.getByRole("progressbar")).toHaveAttribute("aria-valuenow", "50"));
    expect(document.querySelector("[data-upload-progress]")).toHaveTextContent("pasted.txt");
    expect(document.querySelector("[data-upload-progress]")).toHaveTextContent("5 B / 10 B");

    fireEvent.click(document.querySelector("[data-cancel-upload]")!);
    await waitFor(() => expect(document.querySelector("[data-upload-progress]")).toBeNull());
  });
});

describe("FileDrawer deselection", () => {
  it("Escape and empty-area clicks clear the selection back to root targeting", async () => {
    listDirectory.mockResolvedValue(
      listing("/proj", [entry("src", "directory"), entry("a.txt", "file")]),
    );
    renderDrawer();
    await screen.findByText("a.txt");
    const tree = document.getElementById("file-tree")!;

    // Select src, then Escape -> paste goes to root.
    fireEvent.keyDown(tree, { key: "ArrowDown" });
    fireEvent.keyDown(tree, { key: "ArrowDown" });
    fireEvent.keyDown(tree, { key: "Escape" });
    const file = new File(["x"], "p.txt", { type: "text/plain" });
    fireEvent.paste(tree, {
      clipboardData: { items: [{ kind: "file", getAsFile: () => file }], files: [file] },
    });
    await waitFor(() => expect(uploadMultipartFile).toHaveBeenCalled());
    expect(uploadMultipartFile.mock.calls[0][0]).toMatchObject({ fields: { dir: "/proj" } });

    // Re-select, then click the empty area -> selection cleared.
    fireEvent.keyDown(tree, { key: "ArrowDown" });
    fireEvent.keyDown(tree, { key: "ArrowDown" });
    expect(document.querySelector('[aria-selected="true"]')).not.toBeNull();
    fireEvent.click(tree);
    expect(document.querySelector('[aria-selected="true"]')).toBeNull();
  });
});
