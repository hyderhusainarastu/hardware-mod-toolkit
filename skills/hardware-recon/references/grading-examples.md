# Grading examples

Six worked examples, generalized from a real recon session, of a claim moving between confidence
grades and why. The point of each is the *reasoning*, not the specific part -- use these as a
pattern library for adjudicating your own board's disputes.

## 1. UNKNOWN → STRONGLY INDICATED, by fixing an inverted magnification assumption

**The claim:** a connector's contact count -- roughly 14 at one pitch, or roughly 25 at half that
pitch. The two readings described the same physical span, differing by exactly a factor of two:
the textbook signature of spatial aliasing, where a low-resolution view under-resolves a real
pitch into an apparently denser, wrong one.

**What went wrong first:** the photo used to arbitrate the dispute was described as "the closest,
highest-magnification view" and used to overrule the competing reading on that basis alone. Nobody
had actually measured its native pixels-per-millimetre against an internal reference.

**What fixed it:** measuring the connector housing's pixel width in every candidate photo and
comparing it to two independent internal scale references (a known module castellation pitch, a
known connector body dimension) in the *same frame*. The "highest-magnification" photo turned out
to have the *lowest* native resolution on that connector in the entire set -- it was a whole-device
shot where the board occupied a fraction of the frame, not a macro. The genuinely highest-
magnification photo, never previously cited in the dispute, supported the lower count.

**Lesson:** never adjudicate a magnification dispute by which crop "looks" closer. Compute native
px/mm from two independent in-frame references and let that decide which photo gets to arbitrate.

## 2. A reading withdrawn outright -- a real refutation, not a downgrade

**The claim:** the ~25-contacts-at-half-pitch reading from example 1.

**What happened:** once the true native resolution was known, that photo was re-examined at its
own native scale and found to resolve only about 15 comb teeth -- not the ~25 originally claimed.
Worse, the document's own two previously-cited crops of that same photo disagreed with each other.
A reading that can't reproduce itself against its own evidence doesn't get downgraded to
`POSSIBLE` -- it gets **withdrawn** and flagged so nothing downstream keeps citing it.

**Lesson:** a downgrade says "weaker evidence than we thought." A withdrawal says "this specific
number does not survive being checked" -- and a withdrawn reading needs an explicit note saying so,
not a quiet disappearance, because someone will otherwise find the old draft and re-cite it.

## 3. POSSIBLE → STRONGLY INDICATED, by convergent circumstantial evidence (still not CONFIRMED)

**The claim:** which board-level reference designator names an unmarked SMD module.

**The evidence:** the designator was printed immediately at the module's corner; a later, higher-
resolution photo showed the board between the printed text and the module's edge was visibly bare
-- no other unpopulated footprint, no second component body, nothing else the designator could
plausibly be naming.

**The grade:** upgraded from `POSSIBLE` to `STRONGLY INDICATED` -- multiple independent facts
(position, adjacency, absence of any competing candidate) now converge on one answer. It was
**not** promoted to `CONFIRMED`, because the module itself carries no board-side designator
printed on its own body -- there is still no *direct* observation linking the two, only strong
circumstantial convergence. That distinction is the whole point of having four grades instead of
two.

## 4. STRONGLY INDICATED → CONFIRMED, but only by a stronger evidence *tier*, not a better photo

**The claim:** a memory or storage part's exact capacity, originally inferred from a module's
silkscreen suffix following a manufacturer's known naming convention.

**What changed the grade:** not a better photograph -- an actual electrical read-back (a
read-only identification command run over the device's own debug/programming interface) that
returned the part's capacity directly from the silicon.

**Lesson:** photo-based grading has a ceiling. A silkscreen-decoded inference, however well-
corroborated, stays `STRONGLY INDICATED` at best, because it's still an inference from a naming
convention rather than a direct observation of the part. If a read-only electrical measurement is
available and safe to take, it is a categorically stronger form of evidence than any photograph,
and is worth taking specifically to close a `STRONGLY INDICATED` claim that photography cannot
push further on its own.

## 5. CONFIRMED → STRONGLY INDICATED, by finding the counterexample the inventory had missed

**The claim:** "the [primary connector] is the only external power input on the board."

**What downgraded it:** a second connector was found, unlabeled, whose function was genuinely
unknown -- it could plausibly be a second power input, a second cell, or something unrelated
entirely. The instant a second candidate existed, "the only" stopped being something a photo could
support at `CONFIRMED`, even though nothing about the original connector's identification had
changed.

**Lesson:** any claim of the form "the only X" or "the sole Y" is a claim about the *completeness*
of your inventory, not just about the thing you found. It is only as strong as your confidence
that nothing else on the board plausibly competes for that role -- and a single genuinely-unknown
connector is enough to take it down a grade until that connector's purpose is resolved.

## 6. A refuted misread, recorded rather than incorporated

**The claim:** several analysts independently reported that a particular reference-designator
number appeared twice on the same board (once was even reported as three separate designators
appearing in duplicate).

**Why it wasn't accepted:** duplicate designators are implausible on a normally-numbered board --
if a project's own convention numbers active parts sequentially with no gaps, a repeated number is
far more likely to be two analysts misreading two *different*, adjacent designators than a real
manufacturing anomaly. Nothing in the photos ruled out the two most likely misread pairs.

**What was recorded:** the observation ("several analysts reported this designator twice") was
kept as a note and flagged for the re-shoot, explicitly labeled as a suspected misread -- and it
was not used to support any downstream conclusion.

**Lesson:** an implausible reading that conflicts with the board's own visible conventions doesn't
need to be resolved before you can move on -- it needs to be recorded as disputed and excluded from
anything built on top of it, exactly like an unresolved `UNKNOWN`.
