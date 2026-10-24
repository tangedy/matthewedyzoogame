# Thumbnail GPT

A ready-made ChatGPT setup for Roblox thumbnails for Wash The Farm Animals. Once it's set up, one short message ("shot 1", "kaiju fire hose", "random") gives a finished thumbnail.

| File | Goes where |
| --- | --- |
| `instructions.md` | Pasted into the GPT's **Instructions** box (under the 8,000-character limit). |
| `style-guide.md` | Uploaded as **Knowledge**. The full Roblox art rules. |
| `game-brief.md` | Uploaded as **Knowledge**. Animals, tools, rarities, mutations and the farm look. |
| `shot-library.md` | Uploaded as **Knowledge**. 12 numbered thumbnail concepts. |
| `crop-to-16x9.ps1` | Kept on your PC. Crops the results to 1920x1080. |

## Setup (once, about 2 minutes)

Custom GPTs need ChatGPT Plus or higher.

1. In ChatGPT, open **Explore GPTs → Create**, then the **Configure** tab.
2. **Name:** Farm Thumbnail Maker. **Description:** Roblox thumbnails for Wash The Farm Animals.
3. **Instructions:** paste the whole of `instructions.md`.
4. **Knowledge:** upload `style-guide.md`, `game-brief.md` and `shot-library.md`.
5. **Capabilities:** turn on **Image Generation**. Turn off Web Search.
6. **Conversation starters** (optional): `shot 1`, `random`, `kaiju fire hose`, `rainbow unicorn "RAINBOW UNICORN!"`.
7. Click **Create**, and keep it private (Only me).

If you don't want a custom GPT, a **ChatGPT Project** works the same way: put `instructions.md` in the project's instructions and add the three knowledge files to the project's files.

## Using it

Type one short message:

- `shot 4`: a concept from the shot library.
- `random`: a shot you haven't made yet in this chat.
- `dragon getting foam cannoned at night`: your own idea. The GPT fills in the rest.
- `shot 2 "CAN YOU WASH IT?"`: quoted words become title text. With no quotes there's no text.
- `shot 2 with title`: uses the shot's suggested title.

Then edit with short follow-ups in the same chat: `make the pig gold`, `more mud`, `make it night`, `bigger title`.

Start a new chat when you want a fresh look. Long chats drift toward the earlier images.

## Cropping to 16:9

ChatGPT makes landscape images at 3:2, not 16:9, so the instructions keep everything important away from the top and bottom edges. To crop:

1. Save the images into a `raw` folder next to the script.
2. Run:

```bash
powershell -ExecutionPolicy Bypass -File thumbnail-gpt/crop-to-16x9.ps1
```

Each image gets a centred 1920x1080 copy named `<name>_16x9.png`. You can also pass files directly: `crop-to-16x9.ps1 pig.png kaiju.png`.

## Tweaking

- **New animal or feature:** add it to `game-brief.md` and upload it again.
- **New concept:** add a numbered shot to `shot-library.md`.
- **A rule the GPT keeps breaking:** move it from `style-guide.md` into `instructions.md`. The GPT always follows its instructions, but reads knowledge files only when it looks something up.
