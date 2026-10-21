# ADR-0006 — The project is licensed under the Apache License 2.0

- Status: accepted
- Date: 2026-10-21
- Milestone: M2.1
- Related: `LICENSE`, `NOTICE`, `CONTRIBUTING.md`

## Context

`AGENTS.md` deliberately kept the repository without a `LICENSE` file: the
license is a decision, not a formality, and an empty placeholder would have
been worse than no file at all. The decision blocked the `v0.1.0` tag and the
license badge, and it had to be taken before the project accepts contributions
from anyone other than its owner, because every contribution made before the
choice would otherwise need a separate grant.

The project's goal is a self-contained operating system with a kernel, drivers,
libraries and applications, intended to be usable by third parties. That goal
puts two requirements on the license: it must allow proprietary and commercial
use of the system and of the drivers written for it, and it must give
contributors and users a patent grant, because an operating system implements
techniques that patents can reach.

## Decision

AzuraOS is licensed under the **Apache License, Version 2.0**.

* `LICENSE` holds the canonical text, unmodified, as published at
  <https://www.apache.org/licenses/LICENSE-2.0.txt>. Its SHA-256 is
  `cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30`; a
  modified text is not the Apache License and must not be shipped under that
  name.
* `NOTICE` carries the attribution notice. Section 4(d) makes it travel with
  every redistribution, so it is a file of the project, not a courtesy.
* Contributions are accepted under the same license, without a separate
  contributor license agreement. Apache-2.0 section 5 already states that a
  contribution intentionally submitted for inclusion is licensed under the
  terms of the license, unless the contributor says otherwise in writing.
  `CONTRIBUTING.md` says so explicitly so that nobody has to infer it.
* The license applies to what the project writes. Third-party components keep
  their own licenses, and the compatibility layers planned for later
  milestones must respect the licenses of the systems they emulate. Code under
  a license that is incompatible with Apache-2.0 is not linked into the kernel
  or the bootloader; it is, at most, a separate process with its own license
  and its own build.

## Alternatives rejected

* **MIT.** The shortest permissive license, and it would have satisfied the
  ecosystem goal. It was rejected because it contains no patent grant: a
  contributor who holds a patent on a technique implemented in the kernel
  would grant nothing by contributing the code, and a user would have no
  explicit protection.
* **GPL-2.0-or-later.** Stronger sharing obligations for distributed
  derivatives. It was rejected because it would force every distributed
  driver or derived kernel to be released under the same terms, which
  conflicts with the goal of third-party drivers and applications, and because
  the kernel links firmware-facing code whose licensing would then need a
  case-by-case analysis.
* **Dual licensing.** Requires a contributor license agreement that allows the
  project to relicense contributions, and a decision about who may exercise
  that right. The project has one owner and no legal structure for it yet;
  choosing it now would add an obligation without a benefit.

## Consequences

* Redistributions of modified versions do not have to publish their source.
  The project accepts that: the license protects the users' freedom to use and
  modify the system, not the availability of every derivative.
* The patent grant terminates for anyone who sues over the Work, as section 3
  states. That is the intended trade.
* Every dependency must be checked against Apache-2.0 before it is added. The
  check belongs in the review of the change that adds the dependency, and a
  dependency with an unclear license is not added.
* Files modified by a redistributor must carry a prominent notice, and the
  `NOTICE` file must be preserved (sections 4(b) and 4(d)). The project does
  not add per-file license headers: the single `LICENSE` file and the
  `NOTICE` are the notice, and the build does not depend on a header being
  present.
* The `v0.1.0` tag is no longer blocked by the license. It remains blocked by
  the milestone itself.

## References

* <https://www.apache.org/licenses/LICENSE-2.0.txt> — the canonical text.
* <https://www.apache.org/foundation/license-faq.html> — the ASF's licensing
  FAQ, in particular the questions on section 5 and on NOTICE.
* `LICENSE`, `NOTICE`, `CONTRIBUTING.md`.
