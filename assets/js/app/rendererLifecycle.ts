/** Run context-loss recovery only for the addon that still owns the renderer. */
export function recoverOwnedWebglContext(
  ownerGeneration: number,
  currentGeneration: number,
  recover: () => void,
): boolean {
  if (ownerGeneration !== currentGeneration) return false;
  recover();
  return true;
}
