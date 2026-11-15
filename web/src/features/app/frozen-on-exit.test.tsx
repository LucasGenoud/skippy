import { cleanup, fireEvent, render, screen } from "@testing-library/react";
import { AnimatePresence, motion } from "motion/react";
import { createContext, useContext, useState } from "react";
import { afterEach, expect, it } from "vitest";
import { FrozenOnExit } from "./frozen-on-exit";

afterEach(cleanup);

// Stands in for the store: both views read the active collection live.
const Active = createContext("General");
function View() {
  return <p>{useContext(Active)}</p>;
}

it("keeps a leaving view as it last looked while the store moves on", () => {
  function Host() {
    const [active, setActive] = useState("General");
    return (
      <Active.Provider value={active}>
        <button type="button" onClick={() => setActive("Projects")}>
          Switch
        </button>
        <AnimatePresence initial={false}>
          <motion.div key={active} exit={{ opacity: 0, transition: { duration: 10 } }}>
            <FrozenOnExit>
              <View />
            </FrozenOnExit>
          </motion.div>
        </AnimatePresence>
      </Active.Provider>
    );
  }
  render(<Host />);

  fireEvent.click(screen.getByRole("button", { name: "Switch" }));

  // The leaving copy still says General; only the arriving view says Projects.
  expect(screen.getAllByText("General")).toHaveLength(1);
  expect(screen.getAllByText("Projects")).toHaveLength(1);
});
