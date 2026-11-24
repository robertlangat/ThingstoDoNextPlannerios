# App Store Connect listing: Things to Do Next Planner

Paste these into **App Store Connect → your app → App Store** (version page) and **App Information**.
Character limits are noted; every field below fits.

## App Information

| Field | Value |
|---|---|
| Name (30) | `Things to Do Next Planner` |
| Subtitle (30) | `To-do list, reminders & plans` |
| Bundle ID | `com.robertlangat.thingstodonext` |
| SKU | `thingstodonext-ios-001` |
| Primary category | Productivity |
| Secondary category | Lifestyle |
| Content rights | Does not contain third-party content |
| Age rating | 4+ (answer "None" to every content question; see "Age rating" below) |
| Privacy Policy URL | https://robertlangat.github.io/ThingstoDoNextPlannerios/privacy-policy |
| Support URL | https://robertlangat.github.io/ThingstoDoNextPlannerios/support |
| Marketing URL (optional) | https://robertlangat.github.io/ThingstoDoNextPlannerios/ |
| Copyright | `2026 Robert Langat` |

## Version page

**Promotional text (170)**
```
Plan your day in seconds: type a rough list and get a schedule that fits around what you already have. Reminders, repeats, widget and Apple Watch included.
```

**Description (4000)**
```
Things to Do Next Planner helps you see what matters today, finish it, and plan what comes next. It works fully offline, with no account needed.

KNOW WHAT TO DO NEXT
• Today, Upcoming, Inbox, Starred and Completed views
• Overdue tasks are highlighted so nothing slips
• Search everything and filter by list, date, priority or status

CAPTURE IN A SECOND
• Quick add with just a title, or dictate with the keyboard microphone
• Add notes, subtasks, priority, a star, a due date and time, or leave it undated
• Create your own lists with a colour and icon, or start with ready-made lists for personal life, work, study, fitness, travel, wishlists and family events

REMINDERS AND REPEATS THAT JUST WORK
• One or more reminders per task, at the time or before it
• Complete or snooze straight from the notification
• Repeat daily, on weekdays, weekly, monthly, yearly or on your own custom schedule
• Birthdays and anniversaries repeat every year, even on February 29
• Monthly tasks on the 31st land on the last day of shorter months
• Edit just this occurrence, or this and all future ones

FOCUS VIEW
• A calm screen with your top three priorities, big checkboxes and one-tap rescheduling

CALENDAR
• Day, week and month views with all-day and timed tasks
• Add a task straight onto any day

PLAN MY DAY
• Type a goal or a rough list, like "I have two hours after work: revise for my exam and do the errands"
• Get a draft schedule with time slots that avoids what you've already planned
• Edit, untick or move anything before saving

TRACK YOUR PROGRESS
• See completions for today and this week, overdue tasks, and progress for every list
• Repeating tasks count each occurrence, so your streaks stay honest

WIDGET AND APPLE WATCH
• Home-screen widget shows today's tasks; tick them off without opening the app
• Apple Watch app shows today's tasks and upcoming deadlines, and lets you complete tasks from your wrist

YOUR DATA, YOUR WAY
• Everything is stored on your device and works offline
• Export and import backup files with the Files app
• Light, dark or system appearance, with a choice of accent colours

Things to Do Next Planner is free and supported by ads.
```

**Keywords (100, comma-separated, no spaces after commas)**
```
todo,to-do,task,planner,reminder,checklist,schedule,daily,habit,organizer,calendar,focus,productivity
```

**What's New (first version)**
```
First release: tasks, lists, reminders, repeating tasks, calendar, focus view, day planner, widget and Apple Watch app.
```

## Screenshots

Upload from the `store-assets` branch / `app-store-assets` release (folder `framed/` for captioned, or `raw/` for plain):

| App Store Connect slot | Files | Size |
|---|---|---|
| iPhone 6.9" Display | `framed/iphone/01-today.png` … `06-mine.png` | 1320 × 2868 |
| iPad 13" Display | `framed/ipad/01-today.png` … `06-mine.png` | 2064 × 2752 |
| Apple Watch | `raw/watch/today.png` | 416 × 496 (Series 10, 46 mm) |

App Store Connect scales the 6.9" and 13" screenshots down for smaller devices automatically.

## App Privacy ("nutrition label")

The app itself collects nothing; all tasks stay on the device. **Google AdMob** collects data for
ads, so answer **Yes, we collect data** and declare the following. Google's own guidance is at
developers.google.com/admob/ios/privacy/data-disclosure.

| Data type | Linked to user? | Used for tracking? | Purposes |
|---|---|---|---|
| Identifiers → Device ID (IDFA, only if the user allows tracking) | No | Yes | Third-Party Advertising |
| Usage Data → Advertising Data | No | Yes | Third-Party Advertising, Analytics |
| Usage Data → Product Interaction | No | No | Analytics |
| Diagnostics → Crash Data, Performance Data | No | No | App Functionality, Analytics |
| Location → Coarse Location (derived from IP by the ad SDK) | No | Yes | Third-Party Advertising |

If you later ship builds with Google Drive sync enabled, also declare **Contact Info → Email
Address** (Linked: Yes, Tracking: No, Purpose: App Functionality) and **User Content → Other
User Content** (Linked: Yes, Tracking: No, Purpose: App Functionality).

## Age rating

Answer **None / No** to every question. For "Unrestricted Web Access", answer **No**. Contests,
gambling and medical content are all **No**. If the questionnaire asks about messaging, user-generated
content or in-app controls, answer **No**. The result is **4+**. Ads are allowed at 4+ because
the AdMob units serve general-audience ads (set "Max ad content rating: G" in AdMob → App settings).

## App Review information

**Sign-in required:** No.

**Notes for the reviewer:**
```
No account is needed; all features work offline.
- Add a task with the + button on the Tasks or Calendar tab.
- Notifications are requested only when you turn on reminders or add a reminder to a task.
- "Plan my day" is on the Tasks tab (sparkles icon) and on the Mine tab; it runs on the device.
- Ads are served by Google AdMob. The consent form appears where required by law, then the App Tracking Transparency prompt.
- The home-screen widget and the Apple Watch app show today's tasks and let you complete them.
```

**Export compliance:** The app uses only standard HTTPS. `ITSAppUsesNonExemptEncryption` is
already set to `NO`, so no questions are asked.

**Advertising identifier (IDFA):** Yes, the app uses it (through AdMob) to serve ads. It asks for
permission with App Tracking Transparency first.
