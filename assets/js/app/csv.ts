/** Minimal RFC-4180 CSV parser: quoted fields, escaped quotes, newlines in quotes. */
export function parseCsv(text: string, delimiter = ","): string[][] {
  const rows: string[][] = [];
  let row: string[] = [];
  let field = "";
  let inQuotes = false;
  let i = 0;

  const pushField = () => {
    row.push(field);
    field = "";
  };
  const pushRow = () => {
    pushField();
    rows.push(row);
    row = [];
  };

  while (i < text.length) {
    const ch = text[i];

    if (inQuotes) {
      if (ch === '"') {
        if (text[i + 1] === '"') {
          field += '"';
          i += 2;
        } else {
          inQuotes = false;
          i += 1;
        }
      } else {
        field += ch;
        i += 1;
      }
      continue;
    }

    if (ch === '"' && field === "") {
      inQuotes = true;
      i += 1;
    } else if (ch === delimiter) {
      pushField();
      i += 1;
    } else if (ch === "\r" && text[i + 1] === "\n") {
      pushRow();
      i += 2;
    } else if (ch === "\n" || ch === "\r") {
      pushRow();
      i += 1;
    } else {
      field += ch;
      i += 1;
    }
  }

  // trailing field/row (ignore a single trailing newline's empty row)
  if (field !== "" || row.length > 0) pushRow();

  return rows;
}

/** Guesses the delimiter from the first line: tab, semicolon or comma. */
export function detectDelimiter(text: string, fileName = ""): string {
  if (/\.tsv$/i.test(fileName)) return "\t";

  const firstLine = text.slice(0, text.indexOf("\n") === -1 ? undefined : text.indexOf("\n"));
  const counts: [string, number][] = ["\t", ";", ","].map((d) => [
    d,
    firstLine.split(d).length - 1,
  ]);
  counts.sort((a, b) => b[1] - a[1]);
  return counts[0][1] > 0 ? counts[0][0] : ",";
}
