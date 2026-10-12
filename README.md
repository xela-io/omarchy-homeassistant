# Home Assistant Dashboard for Omarchy

An Omarchy bar widget that brings your [Home Assistant](https://www.home-assistant.io/)
dashboard into the bar. There is nothing to arrange in the widget:
it shows what your dashboard shows.

![The popup with rooms, lights, scenes and sensors](preview.png)

The popup mirrors one of your dashboards; with more than one, a row of
buttons at the top switches between them and the choice is remembered in
`~/.config/omarchy/home-assistant.json`. If a dashboard is auto-generated,
it groups entities by area the way Home Assistant does, leaving out
unavailable entities. Entities without an area land in a folded "Other"
section. Every section folds with a click on its header.

- **Lights, switches, fans, input booleans** — on/off switch; dimmable lights
  get a brightness slider while on.
- **Scenes, scripts, buttons** — run with one click.
- **Covers** — open / stop / close. **Climate** — current → target
  temperature with ± steps. **Media players** — play/pause.
- **Sensors** and everything else — value with unit.

States update live over Home Assistant's WebSocket API, so changes made
elsewhere show up immediately. The icon turns yellow while any light is on
and red when the connection is down. The tooltip shows how many lights are
on. Left-click opens the popup, right-click reconnects.

## Requirements

- Omarchy with the Quickshell-based bar
- `python3` (standard library only)
- `secret-tool` (libsecret) with a running keyring such as GNOME Keyring

## Installation

```bash
omarchy plugin add https://github.com/xela-io/omarchy-homeassistant.git --enable --yes
```

### Configuration

1. Point the widget at your Home Assistant if it is not at
   `http://homeassistant.local:8123`:

   ```bash
   echo '{ "url": "http://100.x.y.z:8123" }' > ~/.config/omarchy/home-assistant.json
   ```

2. In Home Assistant, open your profile → *Security* and create a
   long-lived access token.
3. Store it in the keyring, using the same URL:

   ```bash
   secret-tool store --label="Home Assistant" service home-assistant url http://100.x.y.z:8123
   ```

4. Right-click the bar icon to reconnect.

### Language

The popup is in German when the system locale is German and in English
otherwise. Pin it with a `language` setting on the widget's entry in
`~/.config/omarchy/shell.json`:

```json
{ "id": "xela.home-assistant", "language": "de" }
```

## How it works

`ha.py` holds one WebSocket connection and talks to `BarWidget.qml` in JSON
lines: status, layout and states go out on stdout, service calls come in on
stdin. It reconnects on its own with backoff. Run it by hand to debug:

```bash
python3 ~/.config/omarchy/plugins/xela.home-assistant/ha.py
```

## Removal

```bash
omarchy plugin remove xela.home-assistant --yes
```
