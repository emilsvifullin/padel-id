Padel ID 1.2.0 turns the app into a social and sports platform, rebuilds its interface on a design system taken from the app icon, and fixes reachability on home networks. Accounts, rating maths, four-player confirmation and the result outbox are unchanged.

## What changes

**Network.** Direct measurements on the owner's networks show the carrier drops TCP to the Vercel addresses that `padel-id-gamma.vercel.app` resolves to, while `api-padel.shiftregister.ru` (same project) resolves to reachable ones. The build now uses the reachable hostname first and keeps the other as a fallback route; the fallback setting accepts several origins. The transport error no longer claims the device is offline. A relay can report the caller address to the API under a shared key (`PADELID_RELAY_KEY`), which a further entry point for mobile data needs.

**Design.** Lime carries ink in both themes (player ID card, primary actions, chosen values, own chat bubbles, won sets), the racket's six perforation dots show rating reliability and act as the loader, large titles and numerals use expanded SF Pro. Neutrals are the system grouped colours, so lists, forms, sheets and bars stay native; Liquid Glass is kept to navigation and floating bars. Cards grow into their screens, actions confirm with haptics, everything stands still under Reduce Motion. Rules: `docs/ios-architecture.md`, "Visual language".

**Product.** Community is a feed with chats, groups, friends and suggested players one tap away; chats use bubbles and a floating composer. Private games with invitations, waitlists and weekly series; trainings with verified coaches; Americano, Mexicano, King of the Court and Round Robin tournaments; a club catalogue with list and map, club news and verified external booking links. Statistics gain achievements counted from confirmed results only. Three Home Screen icons and Automatic/Light/Dark appearance.

**Backend.** Twelve migrations after the fourteen in production, private avatar storage, group ownership transfer on account deletion, moderation of reported content. Padel ID 1.1.0 keeps working against the new server: its routes and response shapes are unchanged, and because it loads avatars without a session, the gateway reads the current photo of a player who is not hidden on its behalf with the gateway secret, while Storage itself stays private.

## Not in this release

- Remote push: the app is sideloaded with a free Apple ID, which cannot carry the APNs entitlement. The code is present, the build flag is off.
- Photos in posts.
- In-app court booking; only a verified link to the club's own service.
- MegaFon mobile data without VPN still fails for both hostnames; it needs a third entry point (see `docs/verification/network-audit-1.2.0.md`).

## Verification

- Server: typecheck, 109 unit tests; backend CI (SQL, concurrency, end-to-end) green on this branch.
- iOS: unit tests and the full UI suite run locally on iPhone 17 Pro; the four-configuration CI matrix runs on this PR. The Home/Appearance accessibility audit was rewritten for the new layout with the same five system audits in both themes.
- Screens were reviewed in the simulator in Light, Dark and at an accessibility text size.
- Not done: installation and acceptance on a physical iPhone; production migrations, API deployment and the GitHub Release.

Procedure: `docs/release-1.2.0.md`. Current state and what is left: `HANDOFF.md`.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
