# Introduction

Are you tired of calculating adjacency bonuses for your districts?

This mod can help you plan the placement of your districts by calculating the potential yields and adjacency bonuses on your behalf.

Simply add map tacks on your map and the yields from them will show up automatically.

Enjoy planning!

# Features

1. Show map tack's potential yields from itself and adjacency bonuses.
1. Indicate if the map tack represented district or wonder can be placed at the given position.
1. Add hotkeys for adding/deleting and showing/hiding map tacks. Keys can be configured through "Game Options -> Key Bindings".
1. Allow double clicking map tack icon in the selection popup to confirm tack placement.
1. Auto delete the map tack if the represented district or wonder or improvement is added to the given plot.

# Some FAQ

1. Will the tack assume the features or resources are removed when calculating the bonuses?
Ans: Yes, but it depends. If the certain district or improvement is compatible with the features or resources beneath it, it will make them stay. For example, placing city center on top of resources will not remove them (if you hover on the plot, you will see the resource stays). Placing Mbanza on top of woods will not remove the woods. Similar for Vietnam's UA, where districts will be built on features.

2. There's no tool tip for improvements, is that intended?
Ans: As we develop, we found it not super helpful to show detailed bonuses for improvements, since there are not many. Also the default Game database didn't provide us the narratives for improvement's bonuses. If many of you think it'll be helpful, we will add it to our to-do list.

3. Is this mod compatible with other UI mods?
Ans: For the common mods that we are testing with, yes. Most mods won't touch the Map Tacks related logic, so we would think it should be compatible with most of mods. But if you do see any incompatibility with other mods, please let us know and we will try to accommodate.

4. Does your mod support custom districts from other mods?
Ans: If the custom district has simple adjacency bonus like terrains, features, etc, this mod should support them out of the box. If you do see anything missing from the calculation, let us know and we will try to add them.

5. What adjacency bonuses do you support?
Ans: We support all adjacency bonuses that come from the Game database, like Mountain adjacency for Campus. We also support limited set of modifier bonuses, like Sacred Path Pantheon. We are working to support more modifier bonuses.

6. I subscribed the mod, but the yields didn't show up on the tacks.
Ans: Make sure you enable the mod through "Additional Content"->"Mod". You can verify if the mod is enabled in your game through "ESC"-> "Mods in use". Also, if you are creating games by loading from your previously saved game configuration, you have to recreate the game configuration with the mods enabled. Existing game configuration won't include newly subscribed mods I believe.