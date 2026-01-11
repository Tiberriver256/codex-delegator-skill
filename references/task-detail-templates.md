# Task Detail Templates

Reusable task briefs for common delegation patterns.

## Feature Extraction

```
Repository path: /path/to/repo

Analyze the repository thoroughly. For each distinct user-facing feature:
1. Create a separate .feature file named descriptively (e.g., user-authentication.feature)
2. Write a Feature description explaining what the feature does
3. Write Scenarios in plain user-facing language (not technical implementation details)
4. Use Given/When/Then format
5. Include happy path and key edge cases

Output all .feature files to: /path/to/output/features/
```

## Architecture Extraction

```
Repository path: /path/to/repo

Analyze the repository thoroughly. Extract:

1. Architecture Decision Records (ADRs):
   - Create ADR markdown files in standard format (Title, Status, Context, Decision, Consequences)
   - Focus on: communication protocols, data flow patterns, state management approaches,
     security patterns, caching strategies, sync mechanisms, API design patterns
   - Ignore specific tech choices (don't write an ADR about 'choosing React' - instead
     document the pattern like 'component-based UI architecture')
   - Name files like: 0001-<decision-title>.md

2. Quality Attribute Scenarios as Gherkin:
   - Create .feature files for quality attributes (performance, scalability, security,
     reliability, maintainability, etc.)
   - Express measurable/testable scenarios

Output ADRs to: /path/to/output/architecture/adrs/
Output QA scenarios to: /path/to/output/architecture/quality-attributes/
```

## Code Migration

```
Source: /path/to/old/code
Target: /path/to/new/location

Migrate the following components:
1. [Component A] - preserve all functionality
2. [Component B] - update to new API patterns

Requirements:
- Maintain backward compatibility
- Add deprecation warnings to old code
- Write migration tests
- Document breaking changes in MIGRATION.md
```

## Bug Investigation

```
Issue: [Description of the bug]
Reproduction steps: [How to trigger it]
Expected: [What should happen]
Actual: [What happens instead]

Investigation tasks:
1. Find the root cause
2. Document the issue in a comment
3. Propose a fix (don't implement yet)
4. Identify any related issues
```
