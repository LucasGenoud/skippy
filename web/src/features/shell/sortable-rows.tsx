"use client";

import type { CSSProperties, ReactNode } from "react";
import { DndContext, KeyboardSensor, PointerSensor, closestCenter, useSensor, useSensors, type DragEndEvent } from "@dnd-kit/core";
import { SortableContext, sortableKeyboardCoordinates, useSortable, verticalListSortingStrategy } from "@dnd-kit/sortable";
import { CSS } from "@dnd-kit/utilities";
import { cn } from "cn";

/** Pixels a press must travel before it becomes a drag, so a tap still opens the row. */
const DRAG_ACTIVATION_PX = 4;

export interface SortableHandle {
  /** Spread on the element that starts a drag (the row, or a grip). */
  readonly handleProps: Record<string, unknown>;
  readonly dragging: boolean;
}

/**
 * A vertical list the user reorders by dragging (`DragReorderList`). Rows
 * slide aside as one passes over them; [onMove] gets the moved id and its
 * resting index, the `arrayMove` target the store methods take.
 */
export function SortableRows<T>({
  items,
  idOf,
  onMove,
  children,
  className,
  keyboard = "enabled",
}: {
  items: readonly T[];
  idOf(item: T): string;
  onMove(id: string, newIndex: number): void;
  children(item: T, handle: SortableHandle, index: number): ReactNode;
  className?: string;
  /**
   * "disabled" where whole rows are the drag handle and Enter must still open
   * them (the sidebar); keyboard reordering needs a grip of its own.
   */
  keyboard?: "enabled" | "disabled";
}) {
  const pointer = useSensor(PointerSensor, { activationConstraint: { distance: DRAG_ACTIVATION_PX } });
  const keys = useSensor(KeyboardSensor, { coordinateGetter: sortableKeyboardCoordinates });
  const sensors = useSensors(pointer, keyboard === "enabled" ? keys : null);
  const ids = items.map(idOf);

  const onDragEnd = (event: DragEndEvent): void => {
    const { active, over } = event;
    if (!over || active.id === over.id) {
      return;
    }
    const newIndex = ids.indexOf(String(over.id));
    if (newIndex >= 0) {
      onMove(String(active.id), newIndex);
    }
  };

  return (
    <DndContext sensors={sensors} collisionDetection={closestCenter} onDragEnd={onDragEnd}>
      <SortableContext items={ids} strategy={verticalListSortingStrategy}>
        <div className={className}>
          {items.map((item, index) => (
            <SortableRow key={idOf(item)} id={idOf(item)}>
              {(handle) => children(item, handle, index)}
            </SortableRow>
          ))}
        </div>
      </SortableContext>
    </DndContext>
  );
}

function SortableRow({ id, children }: { id: string; children(handle: SortableHandle): ReactNode }) {
  const { attributes, listeners, setNodeRef, transform, transition, isDragging } = useSortable({ id });
  const style: CSSProperties = {
    transform: CSS.Translate.toString(transform),
    transition,
  };
  return (
    <div ref={setNodeRef} style={style} className={cn("relative", isDragging && "z-10")}>
      {children({ handleProps: { ...attributes, ...listeners }, dragging: isDragging })}
    </div>
  );
}
