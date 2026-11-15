import { CircleAlert } from "lucide-react"

import { Reveal } from "./reveal"

// Last line of defence: a red box with nothing in it tells someone their
// sign-in failed and then refuses to say how.
const FALLBACK = "Something went wrong. Try again in a moment."

/** A soft error banner above a form's submit button (sign-in, reset). */
export function FormErrorBanner({ message }: { message: string }) {
  const text = message.trim() || FALLBACK
  return (
    <div role="alert" className="flex items-start gap-2 rounded-md bg-error-container px-3 py-2.5 text-[13px] leading-5 text-on-error-container">
      <CircleAlert className="mt-px size-[18px] shrink-0" />
      <span className="min-w-0 flex-1">{text}</span>
    </div>
  )
}

/** The banner, growing in when `message` arrives and collapsing when it clears. */
export function AnimatedFormError({ message, className = "pt-4" }: { message: string | null; className?: string }) {
  return (
    <Reveal>
      {message === null ? null : (
        <div className={className}>
          <FormErrorBanner message={message} />
        </div>
      )}
    </Reveal>
  )
}
