# Cross-platform UI

The game builds its ScreenGuis in code. `src/client/UI` measures the device, scales those guis, and binds actions. This page is the Studio-side setup that matches that code: where `UIScale`, `UIAspectRatioConstraint`, and `UISizeConstraint` go, and where they must not.

`ClientBootstrap` calls `UIPlatform.start()` before any controller runs. You do not add a second LocalScript.

## What decides the layout

Two signals, read on every change:

| Signal | Used for | Values |
| --- | --- | --- |
| `camera.ViewportSize` | Structural layout and `UIScale` | **Mobile** under 600 wide, or a touch screen whose short side is under 500 (any phone, either orientation). **Tablet** 600–1024, **PC** wider than 1024 |
| `UserInputService.PreferredInput` | Which physical inputs are live | `Touch`, `KeyboardAndMouse`, `Gamepad` |

`TouchEnabled`, `KeyboardEnabled`, and `GamepadEnabled` are not read. A touchscreen laptop reports all three as true, so they cannot decide layout.

`PreferredInput` and `ViewportSize` are independent. A 900px-wide iPad with a keyboard is a **Tablet** form factor (the UI scales as a tablet) and **KeyboardAndMouse** input (no WASH button). A landscape phone is 700–930px wide but under 500px tall, so with touch input it is **Mobile**, not Tablet. A short desktop window keeps the width rule.

While the game is running, `PlayerGui` shows the current reading as attributes: `UIFormFactor`, `UIInputMode`, `UIScale`.

## ScreenGui checklist

For every new ScreenGui under `PlayerGui`:

1. `ResetOnSpawn` = **false**. The controllers build the gui once.
2. `ZIndexBehavior` = **Sibling**.
3. `ScreenInsets` = **CoreUISafeInsets** for HUD text (clears the top bar). Use **DeviceSafeInsets** only on a gui whose buttons sit against the physical screen edge.
4. Leave `IgnoreGuiInset` **off** for ordinary HUD. Turn it on only when children are positioned in raw viewport pixels (the reticle, the mud splat, the storm banner). Those guis are excluded from scaling, below.
5. Do **not** parent `UIAspectRatioConstraint` or `UISizeConstraint` to the ScreenGui. A ScreenGui is not a GuiObject. The engine ignores both constraints there.
6. Do **not** add your own `UIScale` named `ResponsiveScale`. The scaler creates that one child and drives it. A second scale on the ScreenGui fights it. Scales on a **child** frame are fine: pop and bounce animations multiply with the screen scale.

### Which existing guis are scaled

The scaler does **not** touch every ScreenGui. `PlayerGui` also holds engine and plugin guis (`TouchGui`, `ContextActionGui`, `Freecam`). Scaling those shrinks the thumbstick, the jump button, and the WASH button lined up with it.

| ScreenGui | Scaled | Why |
| --- | --- | --- |
| HUD, Shop, Index, Zoo, Onboarding, Tension, Monetization, LiveOps, LiveOpsPopups, FriendLuck, CheckIn, GuideInstruction, OverflowPrompt, PaidConfirm | Yes | Named game HUD. Child pop-scales multiply with the screen scale. |
| SprayControls | No | The reticle position is a viewport pixel. |
| MobileControls | No | The WASH button is sized and placed from the engine jump button, in physical pixels. |
| TensionSplat | No | Mud blotches are sized from `ViewportSize`. |
| LiveOpsTop | No | The storm banner is aligned to the top-bar inset. |
| TouchGui, ContextActionGui, Freecam, Chat, BubbleChat, Backpack | Never | Engine or Studio UI. `UIPlatformInclude` does not override this. |

A new game ScreenGui is scaled only if its name is added to `GAME_GUIS` in `ScaleDriver`, or you set attribute `UIPlatformInclude` (boolean) to **true** before parenting it. Set `UIPlatformExclude` (or call `UIPlatform.setExcluded(gui, true)`) to keep a named game gui at scale 1.

## The one UIScale

Explorer shape the script maintains:

```text
PlayerGui
  HUD                     ScreenGui
    ResponsiveScale       UIScale          -- script-owned, Scale is driven
    Wallet                Frame
    WashPanel             Frame
      UIScale                                -- animation only, multiplies
```

`ResponsiveScale.Scale` follows the viewport:

- Width 360 or below maps to **0.62**. Width 1280 or above maps to **1**. In between, a smoothstep so the ends do not kink.
- A short window (height under 720) shrinks a little more.
- The form factor then clamps that number: Mobile 0.55–0.80, Tablet 0.55–0.95, PC 0.55–1.00. A normal window already sits inside the clamp, so dragging across 600 or 1024 does not pop.
- PC never goes above 1. The existing desktop offsets stay the size they were built at.
- The first value is applied immediately. Later changes ease in over about 180ms on one shared heartbeat, not a tween per gui.

`UISizeConstraint` runs before this scale. A panel with `MaxSize` 360×250 at screen scale 0.7 draws at about 252×175, and its children shrink with it. That is what you want for the hose shop and the index. Do not also hand-scale those offsets.

## UIAspectRatioConstraint

Parent it to the frame, image, or button that must keep its shape. Never to the ScreenGui, and never to a bar that is supposed to stretch.

### Square icon or action chip

Use this for an index-style button, a close button, or any icon that should stay square when the parent row changes height.

1. Select the `ImageButton` or `TextButton`.
2. Insert **UIAspectRatioConstraint**.
3. Set:
   - `AspectRatio` = **1** (width ÷ height).
   - `AspectType` = **FitWithinMaxSize**. The button stays inside the size you already set instead of overflowing the row.
   - `DominantAxis` = **Height** when the button sits in a horizontal row. Use **Width** when it sits in a vertical stack.
4. Insert **UISizeConstraint** on the **same** object (next section) so a scaled phone cannot shrink the hit target to nothing, and a desktop row cannot grow it without limit.

`FitWithinMaxSize` letterboxes inside the box. `ScaleWithParentSize` forces the ratio even if the widget pokes out of its parent. Use `ScaleWithParentSize` only for a full-bleed illustration, not for HUD chrome.

### Card with art

Wash cards and shop panels are wider than they are tall. Put the constraint on the **card frame**, not on the title label.

1. Select the card `Frame`.
2. Insert **UIAspectRatioConstraint**.
3. Set `AspectRatio` to the authored width ÷ height. A 380×150 wash card is **2.533**.
4. `AspectType` = **FitWithinMaxSize**.
5. `DominantAxis` = **Width** if the card is centered and should get shorter rather than narrower. Use **Height** if it should get narrower rather than shorter.

Do not put a second aspect constraint on the text or the clean-meter inside the card. Those should fill the card (`UDim2` scale) and let the card hold the ratio.

### Leave these without an aspect constraint

- Cash and toast labels. They are one line of `TextScaled` text and must use the width they are given.
- The clean meter and patience bar. They stretch on purpose.
- The reticle. It is a fixed 18×18 circle in viewport pixels, on an excluded ScreenGui.

From code, the same placement is `UIPlatform.constrain(frame, { aspectRatio = 1, dominantAxis = Enum.DominantAxis.Height, minSize = Vector2.new(44, 44), maxSize = Vector2.new(72, 72) })`. That parents `UIPlatformAspect` and `UIPlatformSize` to the frame.

## UISizeConstraint

Parent it to the widget whose box you want to floor or cap. It clamps the widget's size **before** `ResponsiveScale` multiplies the result.

### Centered toast, announcement, or banner

This is the pattern already on the HUD announcement, the bottom toast, and the onboarding banner.

1. Select the label or banner.
2. Size it with scale on X so it tracks the screen, for example `UDim2.new(0.9, 0, 0, 34)`.
3. Insert **UISizeConstraint**.
4. Set `MaxSize` to the longest length that still looks like a caption, not a stretched headline. The HUD uses **720×34** for announcements and toasts, **560×40** for the onboarding banner.
5. Leave `MinSize` at 0, 0 for text. `TextScaled` fills whatever height remains.

### Modal panel

Shop and index already do this. Keep it.

1. Select the panel `Frame`.
2. Size with a mix: scale so a phone can shrink it, offset or `MaxSize` so a desktop does not grow it. The shop is `UDim2.new(0.9, 0, 0, 250)` with `MaxSize` **360×250**. The index is `UDim2.fromScale(0.92, 0.82)` with `MaxSize` **600×560**.
3. Insert **UISizeConstraint** on the panel only. Do not also cap every row inside it. The rows should be scale-sized against the panel so they follow the cap.

### Touch target

For a button a thumb has to hit (close, buy, index):

1. Insert **UISizeConstraint** on the button.
2. `MinSize` = **44×44**. This floor is applied before the screen scale, so on a phone at scale 0.62 the drawn size is about 27px. That is acceptable for a button that also has padding around it. Buttons that must stay physically large belong on the native touch controls (next section), which are **not** inside `ResponsiveScale`.
3. `MaxSize` = the desktop cap, for example **72×72** for an icon and **360×50** for a wide buy button.

`MinSize` larger than `MaxSize` is ignored on the axis that conflicts. Set the max on both axes.

## Actions (keyboard, mouse, gamepad, touch button)

`UIPlatform.ActionMap` binds through `ContextActionService`.

- `PreferredInput == Touch`: the engine draws the virtual button for actions with `touch = true`. Spray is the exception: see **The WASH button** below.
- Keyboard, mouse, and gamepad: the same action name is bound to real keys, and `createTouchButton` is false, so no duplicate button is drawn.
- A touch can also fake a mouse click. In touch mode the mouse button is not bound, so Spray does not fire twice.

The catalog lives in `ActionMap.Templates`:

| Action | Bound now | Keyboard / mouse | Gamepad | Touch button |
| --- | --- | --- | --- | --- |
| Spray | Yes. `CleaningController` holds it to wash. | Left mouse | R2 | None. `UI/WashButton` draws WASH instead |
| Interact | No. Binding it would take **E** and **ButtonX** from ProximityPrompts. | E | ButtonX | Stacked above WASH |
| Sprint | No. Binding it would take **LeftShift** and **ButtonL3** from the character controller. | Left Shift | L3 | Above the thumbstick |

To turn Interact or Sprint on from a controller:

```lua
local UIPlatform = require(script.Parent.Parent.UI)

UIPlatform.ActionMap.bindTemplate("Interact", function(state, _input)
	if state == Enum.UserInputState.Begin then
		-- your action
	end
	return Enum.ContextActionResult.Pass
end)
```

Add a new action by putting a spec next to `Spray` in `ActionMap.Templates` (`name`, `title`, `keyboardMouse`, `gamepad`, `touch`, `touchPosition`, `touchSize`) and calling `bindTemplate`. Touch positions are the button's center. Re-bind happens automatically when `PreferredInput` changes. Button size and position update when the width band changes, without building a new button.

Clicks that land on an `Active` gui (buttons, text boxes) do not start Spray. That replaces the old `gameProcessed` check on `InputBegan`.

## The WASH button

On touch, Spray is a custom button, not an engine action button. An engine button sinks the touch, so the finger holding it can never turn the camera. `UI/WashButton` fixes that:

- It sits centred over the engine jump button, 12px above it, 1.1× its size (at least 76px). It reads `TouchGui > TouchControlFrame > JumpButton` and follows it when the engine moves or resizes it. Until that exists it uses the engine's own jump layout.
- Holding it sprays. Dragging the same finger turns the camera: after the camera script runs, `Camera.CFrame` is rotated around `Camera.Focus`. Pitch stops at ±80°, like the default camera. Speed is `LOOK_SPEED` at the top of the file (radians per pixel), slower than the default touch camera so aiming stays fine.
- Letting go anywhere on screen stops the water. A ring and a knob show while held, so the player sees the finger is steering.
- It hides during the opening cutscene, and sits under every menu: the menu dimmers block it while a panel is open.
- While an animal is waiting to be washed it is full size with a breathing ring, and a bouncing **HOLD!** shows until the first press. Otherwise it shrinks to 86% and fades, so it stays out of the way.
- While it is held, the water locks onto one patch of mud in reach and stays on it until it is clean, then moves to the nearest next patch. Your own animal comes first. The camera never steers the water, so dragging only changes the view. With no mud in reach, it sprays straight ahead of the character. The aim is sent from the nozzle, not the camera, and the server casts from the same point.

## Touch layout

`UIPlatform.Layout` holds the fixed HUD positions for two cases: **Touch** (every phone and tablet, plus any Mobile-width window) and **Desktop** (keyboard or gamepad). A controller calls `Layout.watch(fn)` and places its piece from the spec it gets. The touch layout keeps the thumbs' corners empty: bottom left is the thumbstick, bottom right is jump and WASH.

| Piece | Desktop | Touch |
| --- | --- | --- |
| Cash and income | Bottom left | Top left, under the top bar |
| INDEX / DAILY / SHOP | Left middle text buttons, 170×42, 48 apart | Narrow column of 90×90 icon buttons (📖 🎁 🛒) under the cash, 100 apart (about 50px drawn) |
| Boost timers | Right of the rail | Right of the icon column |
| Invite box | Right middle | Top right |
| Event counter | Free part of the top bar | Same, or just under the bar when Roblox's buttons leave too little room (`GuiService.TopbarInset`) |
| Toasts, carry PUT DOWN / SELL | 140 / 190 up from the bottom | 28 / 24 up, between the thumbstick and WASH |
| Hotbar (Backpack) | Shown | Hidden: the hose re-equips itself, so the slot only covered the screen |

The left-rail buttons register with `Layout.rail(button, order)`. The rail owns their position and size, and a hidden button (DAILY before it unlocks) gives its slot to the next one.

Buttons get their feel from `UIPlatform.Feedback.button(button)`: grow to 1.06 on mouse hover (0.16s), sink to 0.94 on press (0.07s), spring back with a Back ease (0.35s), with a soft tap sound. `Feedback.popIn(scale)` is the panel-open pop.

## Trying it in Studio

1. Play with the device emulator. Changing the emulator width updates `PlayerGui.UIFormFactor` and `UIScale`.
2. The emulator's mouse still reports `PreferredInput` as `KeyboardAndMouse`, so the Spray touch button stays hidden. Switch the emulator to touch input, or test on a phone, to see the native button.
3. Drag the Studio window across about 600px and about 1024px wide. The HUD should ease to the new scale and not jump backward.
4. On desktop, hold left mouse to spray and aim with the cursor. On a gamepad, hold R2 and aim with the center reticle. On touch, hold WASH near an animal: the water locks onto the mud, and dragging the same finger turns only the camera.
5. Click a shop or index button with the mouse. The hose must not start spraying.
