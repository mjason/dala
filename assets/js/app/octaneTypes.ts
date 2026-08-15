import type { JSX } from "octane/jsx-runtime";

export type ComponentProps<T> = T extends (props: infer Props) => unknown ? Props : never;
export type RefObject<T> = { current: T };
export type MutableRefObject<T> = RefObject<T>;
export type CSSProperties = Record<string, string | number | undefined>;
export type InputProps = JSX.IntrinsicElements["input"];
export type TextareaProps = JSX.IntrinsicElements["textarea"];
export type SelectProps = JSX.IntrinsicElements["select"];
export type NativeKeyboardEvent<T extends EventTarget = Element> = KeyboardEvent & {
  currentTarget: T;
};
export type NativeMouseEvent<T extends EventTarget = Element> = MouseEvent & {
  currentTarget: T;
};
export type NativePointerEvent<T extends EventTarget = Element> = PointerEvent & {
  currentTarget: T;
};
