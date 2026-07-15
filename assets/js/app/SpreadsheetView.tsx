import React, { useEffect, useMemo, useRef, useState } from "react";
import {
  type ColumnDef,
  type ColumnFiltersState,
  type FilterFn,
  type SortingState,
  type VisibilityState,
  flexRender,
  getCoreRowModel,
  getFilteredRowModel,
  getSortedRowModel,
  useReactTable,
} from "@tanstack/react-table";
import { useVirtualizer } from "@tanstack/react-virtual";
import { ArrowUpDown, Check, ChevronDown, Columns3, Search, X } from "lucide-react";
import readXlsxFile, { type Sheet } from "read-excel-file/browser";
import { detectDelimiter, parseCsv } from "./csv";
import { rawFileUrl } from "./fileTypes";
import { useI18n } from "./i18n";

type Matrix = unknown[][];
type TableRow = { values: string[] };

type Props = {
  path: string;
  csvContent?: string;
  csvTruncated?: boolean;
  wrap: boolean;
};

export default function SpreadsheetView({ path, csvContent, csvTruncated, wrap }: Props) {
  const { t } = useI18n();
  const [sheets, setSheets] = useState<{ name: string; data: Matrix }[]>([]);
  const [activeSheet, setActiveSheet] = useState(0);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const isExcel = /\.(xlsx|xlsm)$/i.test(path);

  useEffect(() => {
    const controller = new AbortController();

    async function load() {
      setLoading(true);
      setError(null);
      setActiveSheet(0);

      try {
        if (isExcel) {
          const response = await fetch(rawFileUrl(path), {
            credentials: "same-origin",
            signal: controller.signal,
          });
          if (!response.ok) throw new Error(`${response.status} ${response.statusText}`);
          const parsed = await readXlsxFile(await response.arrayBuffer());
          setSheets(parsed.map((sheet: Sheet) => ({ name: sheet.sheet, data: sheet.data })));
        } else {
          let content = csvContent ?? "";
          if (csvTruncated) {
            const response = await fetch(rawFileUrl(path), {
              credentials: "same-origin",
              signal: controller.signal,
            });
            if (!response.ok) throw new Error(`${response.status} ${response.statusText}`);
            content = await response.text();
          }
          setSheets([{ name: path.toLowerCase().endsWith(".tsv") ? "TSV" : "CSV", data: parseCsv(content, detectDelimiter(content, path)) }]);
        }
      } catch (reason) {
        if (controller.signal.aborted) return;
        setError(reason instanceof Error ? reason.message : String(reason));
      } finally {
        if (!controller.signal.aborted) setLoading(false);
      }
    }

    void load();
    return () => controller.abort();
  }, [csvContent, csvTruncated, isExcel, path]);

  if (loading) {
    return <div className="grid min-h-0 flex-1 place-items-center text-sm text-fg-muted">{t("loading")}</div>;
  }

  if (error) {
    return (
      <div className="grid min-h-0 flex-1 place-items-center px-6 text-center text-sm text-danger">
        {t("spreadsheetLoadFailed")}: {error}
      </div>
    );
  }

  const sheet = sheets[activeSheet];
  return (
    <div className="flex min-h-0 flex-1 flex-col bg-bg0">
      {sheets.length > 1 && (
        <div className="flex shrink-0 gap-0 overflow-x-auto border-b border-line bg-bg1 px-2 pt-1.5" role="tablist">
          {sheets.map((candidate, index) => (
            <button
              key={`${candidate.name}-${index}`}
              role="tab"
              aria-selected={index === activeSheet}
              onClick={() => setActiveSheet(index)}
              className={`min-w-24 shrink-0 border-b-2 px-3 py-1.5 text-left text-xs transition-colors ${
                index === activeSheet
                  ? "border-mint font-medium text-fg"
                  : "border-transparent text-fg-muted hover:text-fg"
              }`}
            >
              {candidate.name}
            </button>
          ))}
        </div>
      )}
      <DataGrid key={`${activeSheet}-${sheet?.name ?? "empty"}`} matrix={sheet?.data ?? []} wrap={wrap} />
    </div>
  );
}

function DataGrid({ matrix, wrap }: { matrix: Matrix; wrap: boolean }) {
  const { locale, t } = useI18n();
  const { headers, rows } = useMemo(() => normalizeMatrix(matrix), [matrix]);
  const [sorting, setSorting] = useState<SortingState>([]);
  const [globalFilter, setGlobalFilter] = useState("");
  const [columnFilters, setColumnFilters] = useState<ColumnFiltersState>([]);
  const [columnVisibility, setColumnVisibility] = useState<VisibilityState>({});
  const [filterColumn, setFilterColumn] = useState("column-0");
  const [columnsOpen, setColumnsOpen] = useState(false);
  const columnsMenuRef = useRef<HTMLDivElement>(null);

  const includesText: FilterFn<TableRow> = (row, columnId, value) =>
    String(row.getValue(columnId) ?? "")
      .toLocaleLowerCase()
      .includes(String(value).toLocaleLowerCase());

  const columns = useMemo<ColumnDef<TableRow>[]>(
    () =>
      headers.map((header, index) => ({
        id: `column-${index}`,
        accessorFn: (row) => row.values[index] ?? "",
        header,
        minSize: 88,
        size: Math.min(320, Math.max(120, header.length * 9 + 40)),
        filterFn: includesText,
      })),
    // The filter function is stateless and deliberately follows the current locale.
    // eslint-disable-next-line react-hooks/exhaustive-deps
    [headers],
  );

  const table = useReactTable({
    data: rows,
    columns,
    state: { sorting, globalFilter, columnFilters, columnVisibility },
    onSortingChange: setSorting,
    onGlobalFilterChange: setGlobalFilter,
    onColumnFiltersChange: setColumnFilters,
    onColumnVisibilityChange: setColumnVisibility,
    globalFilterFn: includesText,
    columnResizeMode: "onChange",
    getCoreRowModel: getCoreRowModel(),
    getFilteredRowModel: getFilteredRowModel(),
    getSortedRowModel: getSortedRowModel(),
  });

  const filteredRows = table.getRowModel().rows;
  const scrollRef = useRef<HTMLDivElement>(null);
  const virtualizer = useVirtualizer({
    count: filteredRows.length,
    getScrollElement: () => scrollRef.current,
    estimateSize: () => (wrap ? 42 : 30),
    overscan: 12,
  });

  useEffect(() => {
    virtualizer.measure();
  }, [virtualizer, wrap]);

  const virtualRows = virtualizer.getVirtualItems();
  // JSDOM and the first pre-layout browser frame have no measurable viewport.
  const renderedRows = virtualRows.length
    ? virtualRows.map((item) => ({ index: item.index, start: item.start }))
    : filteredRows.slice(0, 20).map((_, index) => ({ index, start: index * (wrap ? 42 : 30) }));
  const totalHeight = Math.max(
    virtualizer.getTotalSize(),
    renderedRows.length * (wrap ? 42 : 30),
  );

  useEffect(() => {
    const onPointerDown = (event: PointerEvent) => {
      if (!columnsMenuRef.current?.contains(event.target as Node)) setColumnsOpen(false);
    };
    window.addEventListener("pointerdown", onPointerDown);
    return () => window.removeEventListener("pointerdown", onPointerDown);
  }, []);

  const selectedColumn = table.getColumn(filterColumn) ?? table.getAllLeafColumns()[0];
  const columnFilterValue = String(selectedColumn?.getFilterValue() ?? "");
  const visibleColumns = table.getVisibleLeafColumns();
  const formatCount = (count: number) => new Intl.NumberFormat(locale).format(count);

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <div className="flex shrink-0 flex-wrap items-center gap-2 border-b border-line bg-bg1 px-2.5 py-2">
        <label className="flex h-7 min-w-44 flex-1 items-center gap-2 rounded border border-line bg-bg0 px-2 text-fg-muted focus-within:border-mint/60 focus-within:text-fg sm:max-w-64">
          <Search className="h-3.5 w-3.5 shrink-0" aria-hidden />
          <input
            type="search"
            value={globalFilter}
            onChange={(event) => setGlobalFilter(event.target.value)}
            placeholder={t("spreadsheetSearch")}
            className="min-w-0 flex-1 bg-transparent text-xs text-fg outline-none placeholder:text-fg-muted/70"
          />
          {globalFilter && (
            <button onClick={() => setGlobalFilter("")} title={t("spreadsheetClear")} className="text-fg-muted hover:text-fg">
              <X className="h-3.5 w-3.5" aria-hidden />
            </button>
          )}
        </label>

        <div className="flex h-7 min-w-56 flex-1 items-center rounded border border-line bg-bg0 sm:max-w-80">
          <select
            value={filterColumn}
            onChange={(event) => setFilterColumn(event.target.value)}
            aria-label={t("spreadsheetFilterColumn")}
            className="h-full max-w-32 border-r border-line bg-transparent px-2 text-xs text-fg outline-none"
          >
            {table.getAllLeafColumns().map((column) => (
              <option key={column.id} value={column.id}>{String(column.columnDef.header)}</option>
            ))}
          </select>
          <input
            value={columnFilterValue}
            onChange={(event) => selectedColumn?.setFilterValue(event.target.value)}
            placeholder={t("spreadsheetFilter")}
            className="min-w-0 flex-1 bg-transparent px-2 text-xs text-fg outline-none placeholder:text-fg-muted/70"
          />
          {columnFilterValue && (
            <button onClick={() => selectedColumn?.setFilterValue(undefined)} title={t("spreadsheetClear")} className="px-1.5 text-fg-muted hover:text-fg">
              <X className="h-3.5 w-3.5" aria-hidden />
            </button>
          )}
        </div>

        <div ref={columnsMenuRef} className="relative">
          <button
            onClick={() => setColumnsOpen((open) => !open)}
            aria-expanded={columnsOpen}
            className="flex h-7 items-center gap-1.5 rounded border border-line bg-bg0 px-2 text-xs text-fg-muted hover:text-fg"
          >
            <Columns3 className="h-3.5 w-3.5" aria-hidden />
            {t("spreadsheetColumns")}
            <ChevronDown className="h-3 w-3" aria-hidden />
          </button>
          {columnsOpen && (
            <div className="absolute right-0 z-30 mt-1 max-h-64 min-w-48 overflow-auto rounded-md border border-line bg-bg1 p-1 shadow-xl">
              {table.getAllLeafColumns().map((column) => (
                <label key={column.id} className="flex cursor-pointer items-center gap-2 rounded px-2 py-1.5 text-xs text-fg-muted hover:bg-bg2 hover:text-fg">
                  <input
                    type="checkbox"
                    checked={column.getIsVisible()}
                    onChange={column.getToggleVisibilityHandler()}
                    className="sr-only"
                  />
                  <span className="grid h-3.5 w-3.5 place-items-center rounded-sm border border-line text-mint">
                    {column.getIsVisible() && <Check className="h-3 w-3" aria-hidden />}
                  </span>
                  <span className="truncate">{String(column.columnDef.header)}</span>
                </label>
              ))}
            </div>
          )}
        </div>
      </div>

      {headers.length === 0 ? (
        <div className="grid min-h-0 flex-1 place-items-center text-sm text-fg-muted">{t("spreadsheetEmpty")}</div>
      ) : (
        <div ref={scrollRef} className="min-h-0 flex-1 overflow-auto">
          <table role="table" className="relative grid min-w-full border-collapse font-mono text-xs" style={{ width: table.getTotalSize() + 48 }}>
            <thead className="sticky top-0 z-20 grid border-b border-line bg-bg2 shadow-sm">
              {table.getHeaderGroups().map((headerGroup) => (
                <tr key={headerGroup.id} className="flex w-full">
                  <th className="grid h-8 w-12 shrink-0 place-items-center border-r border-line text-[10px] font-medium text-fg-muted">#</th>
                  {headerGroup.headers.map((header) => (
                    <th
                      key={header.id}
                      className="relative flex h-8 shrink-0 items-center border-r border-line px-2 text-left font-semibold text-fg"
                      style={{ width: header.getSize() }}
                    >
                      <button
                        onClick={header.column.getToggleSortingHandler()}
                        className="flex min-w-0 flex-1 items-center gap-1.5 text-left"
                        title={t("spreadsheetSort")}
                      >
                        <span className="truncate">{flexRender(header.column.columnDef.header, header.getContext())}</span>
                        <ArrowUpDown className={`h-3 w-3 shrink-0 ${header.column.getIsSorted() ? "text-mint" : "text-fg-muted/60"}`} aria-hidden />
                        {header.column.getIsSorted() && <span className="sr-only">{header.column.getIsSorted() === "asc" ? "ascending" : "descending"}</span>}
                      </button>
                      <button
                        onDoubleClick={() => header.column.resetSize()}
                        onMouseDown={header.getResizeHandler()}
                        onTouchStart={header.getResizeHandler()}
                        className={`absolute inset-y-0 right-0 w-1 cursor-col-resize touch-none hover:bg-mint ${header.column.getIsResizing() ? "bg-mint" : ""}`}
                        title={t("spreadsheetResizeColumn")}
                      />
                    </th>
                  ))}
                </tr>
              ))}
            </thead>
            <tbody className="relative grid" style={{ height: totalHeight }}>
              {renderedRows.map((virtualRow) => {
                const row = filteredRows[virtualRow.index];
                if (!row) return null;
                return (
                  <tr
                    key={row.id}
                    data-index={virtualRow.index}
                    ref={(node) => {
                      if (node) virtualizer.measureElement(node);
                    }}
                    className="absolute left-0 top-0 flex w-full border-b border-line/50 even:bg-bg1/45 hover:bg-bg2/70"
                    style={{ transform: `translateY(${virtualRow.start}px)` }}
                  >
                    <td className="grid min-h-7 w-12 shrink-0 place-items-center border-r border-line/70 px-1 text-[10px] text-fg-muted/70">{row.index + 1}</td>
                    {row.getVisibleCells().map((cell) => (
                      <td
                        key={cell.id}
                        className={`min-h-7 shrink-0 border-r border-line/50 px-2 py-1.5 text-fg-muted ${wrap ? "whitespace-normal [overflow-wrap:anywhere]" : "truncate whitespace-nowrap"}`}
                        style={{ width: cell.column.getSize() }}
                        title={wrap ? undefined : String(cell.getValue() ?? "")}
                      >
                        {flexRender(cell.column.columnDef.cell, cell.getContext())}
                      </td>
                    ))}
                  </tr>
                );
              })}
            </tbody>
          </table>
        </div>
      )}

      <div className="flex shrink-0 items-center justify-between border-t border-line bg-bg1 px-3 py-1.5 font-mono text-[11px] text-fg-muted">
        <span>
          {filteredRows.length === rows.length
            ? t("spreadsheetRows", {
                rows: formatCount(rows.length),
                columns: formatCount(headers.length),
              })
            : t("spreadsheetFilteredRows", {
                shown: formatCount(filteredRows.length),
                count: formatCount(rows.length),
              })}
        </span>
        <span>{formatCount(visibleColumns.length)}/{formatCount(headers.length)} {t("spreadsheetColumns").toLocaleLowerCase()}</span>
      </div>
    </div>
  );
}

function normalizeMatrix(matrix: Matrix): { headers: string[]; rows: TableRow[] } {
  const width = matrix.reduce((max, row) => Math.max(max, row.length), 0);
  if (width === 0) return { headers: [], rows: [] };

  const firstRow = matrix[0] ?? [];
  const usedHeaders = new Map<string, number>();
  const headers = Array.from({ length: width }, (_, index) => {
    const candidate = formatCell(firstRow[index]).trim() || `Column ${index + 1}`;
    const occurrence = usedHeaders.get(candidate) ?? 0;
    usedHeaders.set(candidate, occurrence + 1);
    return occurrence === 0 ? candidate : `${candidate} (${occurrence + 1})`;
  });

  return {
    headers,
    rows: matrix.slice(1).map((row) => ({
      values: Array.from({ length: width }, (_, index) => formatCell(row[index])),
    })),
  };
}

function formatCell(value: unknown): string {
  if (value == null) return "";
  if (value instanceof Date) return value.toLocaleString();
  return String(value);
}
