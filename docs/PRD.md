# PRD: Lumen

Guardrails version: 9 · Last gate run: 19.11.2026 · State: released

## Purpose and users

- Lumen is a native macOS launcher for apps, files, commands and calendar actions.
- It serves keyboard-first Mac users and can be used without a Lumen account.
- Searching and running a local command must work without external integrations.

## Scope and non-goals

- Launcher search, keyboard actions, calendar, clipboard, notes and optional GitHub, mite and AI integrations.
- Direct macOS distribution with user-initiated in-app updates.
- Raycast extensions and dictation are outside the product scope.

## Exposure

- Lumen runs on the user's Mac and exposes no listening service or Lumen account endpoint.
- Release builds check an HTTPS appcast hosted with the GitHub Releases artifacts. Anyone can download public releases.

## Data

- Lumen stores settings, history, clipboard content, notes, AI chats and integration caches under `~/Library/Application Support/Lumen`. These files are not encrypted by Lumen.
- Calendar content comes from EventKit. The [privacy note](../README.md#data-and-privacy) documents external transfers by feature.
- A synthetic Lumen Store backup and restore passed in an isolated home.

## AI usage

- AI is off by default. Users opt in from Settings, which explains that the provider may charge their account. Users supply their own provider configuration. API keys are held in the macOS Keychain.
- AI requests have a 180-second deadline, a 128 KiB text input limit, up to 40 messages, and up to 12 images with a combined 20 MiB limit.
- HTTP providers receive a 16,384-token output ceiling. Lumen also caps visible output at 16,384 UTF-8 bytes. The Codex CLI has a deadline and process-tree termination. Its internal reasoning and spend lack a verified hard cap.
- Lumen reserves at most 500 requests per local calendar day, including failed or cancelled requests. It refuses requests when it cannot persist the counter.
- A local, metadata-only log records provider, model, timing, outcome and tokens when returned. Provider limits, alerts and billing belong to users. Usage and cost data unavailable from the provider remain unknown.

## Architecture and stack

- Swift, AppKit and SwiftUI with local files and macOS services.
- Optional integrations use the Codex, GitHub and mite CLIs and the configured AI endpoints.
- Sparkle 2.10.1 handles updates. Release downloads use HTTPS and EdDSA signatures. The user starts the check from the Lumen menu.

## Deviations from the guardrails

| Rule | Deviation | Reason | Date |
|---|---|---|---|

## Release gate

| Row | Applies | Status | Evidence | Date |
|---|---|---|---|---|
| G1 Secrets | yes | done | Redacted source and history scans on the clean release snapshot. Runtime provider credentials use Keychain. | 19.11.2026 |
| G2 Client boundary | yes | done | The bundle uses an allowlisted public Sparkle key and an HTTPS feed. Runtime provider credentials use Keychain. | 19.11.2026 |
| G3 Input and business rules | yes | done | Local boundary review and offline checks cover typed local and integration parsers, positive mite IDs, exact date and bounded duration, controlled AI request sizes and endpoint syntax, and signed Sparkle metadata. CheckMite refuses -1 before CLI dispatch. Lumen exposes no server-side business boundary. | 19.11.2026 |
| G4 Identity and access | no | not applicable | Lumen exposes no accounts or data routes. Integrations use each user's own CLI login or provider credentials. | |
| G5 Rate limits and budgets | yes | done | Optional BYOK only. No operator-run or operator-paid endpoint. Enable AI is off by default. Settings explains that the provider may charge the user. CheckAILimits verifies the persisted 500-attempt daily limit, refusal of attempt 501 and fail-closed counter storage. | 19.11.2026 |
| G6 AI | yes | done | BYOK caps and consent as above. Offline checks cover typed streaming, prompt delimiters for selected text and Codex transcript, deadline and output limits, and metadata-only logs. Codex is read-only with shell, web, hooks and agent tools disabled for the tested CLI version. Provider metrics not returned are unknown. No operator funds or credentials. | 19.11.2026 |
| G7 Exposure | yes | done | No listening service. Signed GitHub HTTPS QA feed and ZIP verified. Release bundle has the stable HTTPS feed and no ATS exceptions. AI remote endpoints use HTTPS, with loopback HTTP for local providers. GitHub and mite CLI failures use fixed user-facing messages. | 19.11.2026 |
| G8 Data | yes | done | README discloses local files and feature-level transfers. Isolated Store backup and restore passed. AI uses typed metadata-only logs. The production logger and optional CLI failures avoid personal content. | 19.11.2026 |
| G9 Dependencies | yes | done | Release-time upstream audit verified the pinned Sparkle 2.10.1 distribution checksum. Advisories affecting older versions do not apply. GHSA-gcjm-h3jh-p2vc only affects the package installer path. Lumen uses signed feeds and full app ZIP updates. | 19.11.2026 |
| G10 Public repository | yes | done | Clean initial source snapshot with GitHub noreply author and committer, redacted source and history scans, SECURITY.md and recorded pre-push review. Enable and verify private reporting when GitHub makes the public-only setting available. | 19.11.2026 |
| G11 Version | yes | done | Bundle and Settings show 0.3.0. Build 5 exceeds both prereleases. CHANGELOG.md contains 0.3.0 notes. The staged release uses the matching version. | 19.11.2026 |
| G12 Design | yes | done | Native launcher inspected in light and dark using fictional Notes. Actual panel key events cover input focus, selection, actions, dismiss, detail toggle and resizing. Launcher and chat panes have keyboard controls, size bounds and persisted state. Chat width checks and native compile passed. Phone and web surfaces are absent. | 19.11.2026 |
| G13 README and repo page | yes | done | README first screen, feature details, privacy note, fictional screenshot, source quick start and first-launch instructions reviewed. GitHub metadata includes description, topics, MIT, Issues and Discussions. Release notes match the changelog. | 19.11.2026 |
| G14 In-app updates | yes | done | Bonsai installed and relaunched with data retained from [0.3.0-qa.1](https://github.com/jsc2304/lumen-app-qa/releases/tag/v0.3.0-qa.1) (3) to [0.3.0-qa.2](https://github.com/jsc2304/lumen-app-qa/releases/tag/v0.3.0-qa.2) (4) through signed GitHub HTTPS assets on 18.11.2026. Stable public URLs are checked immediately after publication. | 19.11.2026 |

Status: open | done | not applicable (reason in Evidence). A waived row stays open and has a row under Waivers.

## Waivers

| Row | Reason | Issue | Accepted | Until |
|---|---|---|---|---|

## Open points

- Verify the stable appcast and ZIP without credentials immediately after publication.
