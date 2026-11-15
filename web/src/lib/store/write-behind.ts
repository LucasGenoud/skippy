// One write at a time, and never a stale one: a request made while a write is
// running folds into a single follow-up write of the latest state. Ported from
// `_WriteBehind` in `state/notes_store.dart`.
export class WriteBehind {
  private dirty = false;
  private running = false;

  constructor(private readonly write: () => Promise<void>) {}

  request(): void {
    this.dirty = true;
    if (this.running) {
      return;
    }
    this.running = true;
    queueMicrotask(() => void this.drain());
  }

  /** Resolves once nothing is pending; for tests and teardown. */
  async idle(): Promise<void> {
    while (this.running) {
      await new Promise<void>((resolve) => setTimeout(resolve, 0));
    }
  }

  private async drain(): Promise<void> {
    try {
      while (this.dirty) {
        this.dirty = false;
        await this.write();
      }
    } finally {
      this.running = false;
    }
  }
}
