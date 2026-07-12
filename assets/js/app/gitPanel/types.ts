export type GitFile = { path: string; status: string; staged: boolean; unstaged: boolean };
export type Status = {
  repo: boolean;
  root: string | null;
  branch: string | null;
  files: GitFile[];
};
export type Commit = { hash: string; author: string; date: string; subject: string };
export type BranchInfo = { name: string; current: boolean };
export type Branches = { current: string | null; local: BranchInfo[]; remote: BranchInfo[] };

/** Revisions to fetch full file contents from, powering the merge view. */
export type DiffRevs = { repo: string; oldRev: string; newRev: string };

/** Which side of the index a working diff shows (Fork's two lists). */
export type DiffContext = "unstaged" | "staged";

export type DiffTarget =
  | {
      kind: "file";
      title: string;
      text: string;
      truncated: boolean;
      revs?: DiffRevs;
      context: DiffContext;
      file: GitFile;
    }
  | { kind: "commit"; title: string; text: string; truncated: boolean; revs?: DiffRevs };
