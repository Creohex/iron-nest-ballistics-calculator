# IRON NEST Ballistics Calculator

An unofficial, dependency-free Windows calculator for manual heavy-turret aiming in IRON NEST. It continuously listens for an English range, recommends powder charges, and provides the elevation angle on request.

The calculations follow this [manual aiming and ballistics guide](https://www.treyexgaming.com/iron-nest-heavy-turret-simulator-manual-aiming-ballistics-guide/).

<img width="577" height="438" alt="image" src="https://github.com/user-attachments/assets/11e369ff-058f-4c42-b444-dd212519ae3c" />

## Requirements

- Win10/11
- PowerShell
- English (United States) Windows speech-recognition package

## Install Windows speech recognition

1. Open the language settings:
   - Windows 10: **Settings > Time & Language > Language**
   - Windows 11: **Settings > Time & language > Language & region**
2. Add **English (United States)** under **Preferred languages** if it is not present.
3. Select **English (United States) > Options**.
4. Find **Speech** and click **Download**.
5. Open **Settings > Time & Language > Speech** and select **English (United States)** as the speech language.
6. Restart Windows.

If the microphone is blocked, enable application microphone access under **Settings > Privacy > Microphone** on Windows 10 or **Settings > Privacy & security > Microphone** on Windows 11.

## Usage

Double-click **Launch Iron Nest Calculator.bat**. The microphone starts automatically; say a standalone range without a wake word.

For a range of 5,250 meters, any of these work:

- `5250`
- `five thousand two hundred fifty`
- `five kilometers two hundred fifty`
- `five twenty five`
- `five point two five`

Compact and decimal phrases are interpreted as kilometers: `five twenty five` and `5.25` both mean 5,250 meters. Whole numbers are meters.

The first reply confirms only the range and recommended charges: `5,250, 3 charges`.

| Command | Reply |
| --- | --- |
| `angle` | Current calculated elevation angle |
| `charges` | Current charge count |
| `distance` | Current range |
| `repeat` | Last full reply |

Typed input remains available. The **MIC** button pauses or resumes listening.

## Calculation

Each charge provides 5,000 meters of maximum range at 60 degrees:

```text
angle = range * 60 / (charges * 5,000)
```

Faster aiming is enabled by default: the calculator recommends one charge above the minimum when possible, capped at six charges. Disable the checkbox to use the minimum charge count.

Supported range: 1-30,000 meters.

## Command-line use

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\IronNestBallistics.ps1 -RangeMeters 12000
```

Add `-Mode minimum` to disable the extra-charge recommendation.
