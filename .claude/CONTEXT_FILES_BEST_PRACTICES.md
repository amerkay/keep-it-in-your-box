# How to Write Effective CLAUDE.md and .claude/rules Files

Research-backed guidelines synthesized from two 2026 studies: "Evaluating AGENTS.md" (Gloaguen et al., ICML) and "SkillsBench" (Li et al.).

## The Core Paradox

Context files are followed by agents but **don't reliably improve task completion**. LLM-generated context files *reduce* success rates by ~3% while increasing cost by 20%+. Human-written files provide only marginal gains (~4%). The reason: unnecessary instructions make tasks harder, not easier.

However, **focused procedural Skills** (step-by-step domain knowledge) boost performance by +16.2 percentage points. The difference is *what* you write, not *whether* you write it.

## DO

### Write Minimal, Actionable Instructions
- Include **only requirements the agent cannot discover** from the codebase itself
- Specify exact commands for build/test/lint (`pnpm test:run`, not "run the tests")
- Document repo-specific tooling the agent wouldn't guess (custom scripts, unusual CLIs)
- State non-obvious constraints (e.g., "never modify files in `_library/`")

### Use Focused Procedural Guidance
- **2-3 focused topics outperform comprehensive docs.** Tasks with 2-3 skill modules showed +18.6pp improvement; 4+ modules dropped to +5.9pp
- Write step-by-step procedures, not descriptions. "To add a form: 1) use `defineForm()`, 2) add field constructors, 3) render with `FormRenderer`" beats "We use a form-builder system"
- Include one working code example per pattern. Detailed skills with examples (+18.8pp) beat comprehensive documentation (-2.9pp)

### Target Knowledge Gaps
- Skills help most where the agent lacks domain knowledge (healthcare: +51.9pp, manufacturing: +41.9pp)
- For well-known domains like general software engineering, gains are minimal (+4.5pp)
- Focus context files on **your project's unique patterns**, not general programming practices

### Keep It Short
- Median effective skill size: ~1,500 tokens (~600 words)
- Comprehensive/long documentation **hurts** performance (-2.9pp) — agents struggle to extract relevant info from lengthy content
- Every line should pass the test: "Would the agent fail without this?"

## DON'T

### Don't Include Codebase Overviews
- Directory listings and architecture descriptions **do not help agents find relevant files faster** (measured across 4 agents, 2 benchmarks)
- Agents discover file structure through their own exploration tools equally well without overviews
- This is redundant with information the agent extracts by reading the code

### Don't Auto-Generate Context Files
- LLM-generated context files reduce success rates by ~3% on average across all tested agents
- They are highly redundant with existing documentation (READMEs, docstrings, comments)
- Using a stronger model to generate them doesn't help — and can make things worse
- **Exception**: If your repo has almost no documentation, an auto-generated file may help

### Don't Add Generic Best Practices
- "Write clean code", "follow SOLID principles", "add tests" — agents already know these
- Generic instructions increase reasoning cost (+14-22% more thinking tokens) without improving outcomes
- Instructions are followed but following them doesn't help

### Don't Over-Specify
- 16 of 84 tasks in SkillsBench showed *negative* results from skills — conflicting or overly complex guidance hurt
- If the agent already handles something well, adding instructions about it can degrade performance
- Remove instructions that aren't actively preventing mistakes

## Optimal CLAUDE.md Structure

```markdown
# Project Name

One-line description.

## Commands

Exact commands for build, test, lint, format. Nothing else.

## Critical Patterns (2-3 max)

Only patterns that are:
1. Unique to this project
2. Non-obvious from reading the code
3. Frequently needed

For each: a concrete step-by-step procedure with one code example.

## Constraints

Hard rules the agent must not violate. Keep to <10 items.
```

## .claude/rules/ Files

Use for **contextual rules** that apply only to specific file paths or patterns. Same principles apply:
- One rule per file, focused on a single concern
- Procedural (what to do), not descriptive (what exists)
- Only include if the agent would otherwise get it wrong

## Key Numbers

| Metric | Finding |
|--------|---------|
| LLM-generated files | -3% success rate, +20% cost |
| Human-written files | +4% success rate, +19% cost |
| Focused skills (2-3) | +18.6pp success rate |
| Comprehensive docs | -2.9pp success rate |
| Optimal skill size | ~1,500 tokens |
| SW engineering domain gain | +4.5pp (lowest of all domains) |
| Specialized domain gain | +20-50pp (highest) |

## Sources

1. Gloaguen, T. et al. "Evaluating AGENTS.md: Are Repository-Level Context Files Helpful for Coding Agents?" ICML 2026.
2. Li, X. et al. "SkillsBench: Benchmarking How Well Agent Skills Work Across Diverse Tasks." arXiv:2602.12670, Feb 2026.
