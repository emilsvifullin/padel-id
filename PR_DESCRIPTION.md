Padel ID 1.2.0 turns the app into a social and sports platform and rebuilds its interface on a design system taken from the app icon. Accounts, rating maths, four-player confirmation and the result outbox are unchanged.

## What changes

**Design.** Lime carries ink in both themes (player ID card, primary actions, chosen values and segments, own chat bubbles, won sets), graphite carries the header of a game, an event, a club and a profile, the racket's six perforation dots show rating reliability and act as the loader, titles and numerals use expanded SF Pro. The app has its own symbols for a padel racket and a padel court. Everything else follows the system: its navigation bar untouched, a main tab's title on the row of its buttons, the system search field, grouped lists and forms, sheets, Liquid Glass only where the system puts it. Rows set their titles in one line with an ellipsis, words do not break by syllable, facts are joined with commas rather than middle dots. Rules: `docs/ios-architecture.md`, "Visual language".

**Structure.** Home leads with one action, Find a game, with Create next to it. The Matches tab opens upcoming games and trainings with tournaments from two cards. The events catalogue keeps its filters in two rows, the clubs catalogue shows what a club has. Community is a feed with chats, groups, friends and suggested players one tap away.

**Product.** Private games with invitations, waitlists and weekly series; trainings with verified coaches; Americano, Mexicano, King of the Court and Round Robin tournaments; a club catalogue with list and map, club news and verified external booking links. Statistics gain achievements counted from confirmed results only. Three Home Screen icons and Automatic/Light/Dark appearance.

**Motion.** Cards grow into their screens, loaded content fades in, a theme change dissolves; everything stands still under Reduce Motion. Checked frame by frame on a simulator recording.

**Backend.** Eleven migrations after the fourteen in production, private avatar storage, group ownership transfer on account deletion, moderation of reported content. Padel ID 1.1.0 is not supported after the server update: the minimum client build in production is 3.

## Not in this release

- Remote push: the app is sideloaded with a free Apple ID, which cannot carry the APNs entitlement. The code is present, the build flag is off.
- Photos in posts.
- In-app court booking; only a verified link to the club's own service.
- Access without VPN. The build talks to the same single API origin as 1.1.0; on some Russian networks it still works only through VPN. The owner deferred this to a later stage. Measurements and the prepared but undeployed relay (branch `network/ingress-relay`) are in `docs/verification/network-audit-1.2.0.md`.

## Verification

- Server: typecheck and unit tests; backend CI (SQL, concurrency, end-to-end) on this branch.
- iOS: 171 unit tests and 34 UI tests, run locally in Light on iOS 27 and in a true Dark configuration on iPhone 17 Pro Max, iOS 26.5; the CI matrix runs five configurations on this PR, the fifth being an iPhone SE.
- A tour test walks every section with typical and with worst-case data and keeps the screenshots; it also ran on iPhone SE, iPhone 13 mini and iPhone 11.
- The UI test reset now clears the chosen theme, so the dark configurations stay dark for the whole suite; before, most of it ran in Light.
- Not done: installation and acceptance on a physical iPhone.

Procedure: `docs/release-1.2.0.md`.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
