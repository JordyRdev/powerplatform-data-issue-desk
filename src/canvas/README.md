# Canvas app: Report a Data Issue

Responsive canvas app on the Dataverse tables. Each `scr*.yaml` file holds the controls of one screen
and can be pasted onto an empty screen in Power Apps Studio.

| Screen | What it does |
|---|---|
| `scrIssues` | List with status tabs, search and status pills |
| `scrNewIssue` | Form with validation (impact required for critical issues) and `IfError` around the save |
| `scrIssueDetail` | Facts, description, status timeline from Issue logs, and an Escalate action that calls a cloud flow |

Screen and app properties that are not part of the pasted controls:

```
App.Formulas
  ThemePrimary = ColorValue("#E8590C"); ThemeDark = ColorValue("#1F2328"); ThemeText = ColorValue("#24292F");
  ThemeMuted = ColorValue("#656D76"); ThemeSurface = ColorValue("#F6F8FA"); ThemeCard = Color.White;
  ThemeBorder = ColorValue("#D0D7DE");
  MyEmail = Lower(User().Email); MyName = User().FullName; IsPhone = App.Width < 700;

scrIssueDetail.OnVisible
  Refresh(Issues); Refresh('Issue logs'); Set(gblIssue, LookUp(Issues, Issue = gblIssue.Issue))
```

Data sources: `Issues`, `Data sources`, `Issue logs`. Flow: `Issue | Escalate`.
