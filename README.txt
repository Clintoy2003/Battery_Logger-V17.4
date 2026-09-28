BATTERY LOGGER V17.4 — AUTOMATIC BATTERY HEALTH EDITION
Windows 10/11 • Windows PowerShell 5.1 • CPU temperature removed

QUICK START
1. Extract the ZIP into a normal folder (not inside a ZIP preview).
2. Double-click Start-Battery-Logger.vbs. The companion runs hidden and opens the dashboard.
3. The dashboard connects to http://127.0.0.1:8765/ automatically.
4. Click Start to record charge samples. Battery health refreshes automatically.

WHAT BATTERY HEALTH MEANS
Health (%) = Full Charge Capacity / Design Capacity × 100 (capped at 100% for display).
Wear (%) = max(0, 100 − raw capacity ratio).
The companion tries, in order:
1) root\wmi BatteryStaticData + BatteryFullChargedCapacity, paired by battery instance.
2) Win32_Battery capacity fields.
3) Windows powercfg /batteryreport, parsed from the generated report.
Capacity data is cached for 45 seconds so the app does not regenerate a report on every UI poll.

DIAGNOSTICS
Open http://127.0.0.1:8765/api/diagnostics in a browser to see the source, values, and detection notes.
If values remain N/A, Windows/firmware/driver is not exposing valid capacity data. No program can accurately calculate true capacity health without a design-capacity and current-full-charge-capacity source. The dashboard's manual capacity fallback remains available and is clearly labeled.

HIDDEN LAUNCHER
Start-Battery-Logger.vbs hides the PowerShell console and waits for the local API to respond. Start-Companion.bat is a troubleshooting launcher.

STOP
Close the BatteryLogger-Companion.ps1 PowerShell process in Task Manager, or sign out/restart Windows.
