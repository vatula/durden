--
-- collection of hooks and effects
-- currently quite barebone, but intended to grow over time
-- to surpass what we would get from something like compiz
--

-- reused with many effects
flair_supp_clone = function(wnd)
	local props = image_surface_resolve(wnd.canvas);
	local vid = null_surface(props.width, props.height);
	if (valid_vid(vid)) then
		show_image(vid);
		move_image(vid, props.x, props.y);
		image_sharestorage(wnd.canvas, vid);
		expire_image(vid, gconfig_get("flair_speed")+1);
	end
	return vid;
end

-- we keep the shaders and support script separate from the other
-- subsystems so that the effects are easier to develop, test and
-- share outside a full durden setup
--

-- the cloth effect has a rather verbose setup and use, so split
-- it up into two stages, the simulation and the config/setup
local destroy_effects = system_load("tools/flair/destroy.lua", false)();
local create_effects = system_load("tools/flair/create.lua", false)();
local drag_effects = system_load("tools/flair/drag.lua", false)();
local hide_effects = system_load("tools/flair/hide.lua", false)();

local drag_effect = nil;
-- just route the drag/drop events with extra states for begin/end
local function flair_drag_hook(wm, wnd, dx, dy, last)
	if (in_drag) then
		if (last) then
			if (drag_effect) then
				drag_effect.stop(wnd);
				drag_effect = nil;
			end
			in_drag = false;
			show_image(wnd.anchor);
		elseif (drag_effect) then
			drag_effect.update(wnd, dx, dy);
		end
	else
		local cv = gconfig_get("flair_drag");
		in_drag = true;
		blend_image(wnd.anchor, gconfig_get("flair_drag_opacity"));
		if (drag_effects) then
			for i,v in ipairs(drag_effects) do
				if (v.label == cv) then
					drag_effect = v;
					drag_effect.start(wnd);
					return;
				end
			end
		end
	end
end

-- just dispatch the corresponding effect, the extra little detail
-- is that since the handler is likely to create an intermediate surface
-- with a shared storage, we wrap/set the attachment to match the display
-- of the wm rather than the active_display for multi-display purposes.
local function flair_wnd_destroy(wm, wnd, space, space_active, popup)
	local destroy = gconfig_get("flair_destroy");

	if (destroy_effects and destroy_effects[destroy]) then
		display_tiler_action(wm, function()
			destroy_effects[destroy](wm, wnd, space, space_active, popup);
		end);
	end
end

local function flair_wnd_hide(wm, wnd, dx, dy, dw, dh, hide)
	local heffect = gconfig_get("flair_hide");

	if (hide_effects and hide_effects[heffect]) then
		display_tiler_action(wm, function()
			hide_effects[heffect](wm, wnd, dx, dy, dw, dh, hide);
		end);
	else
		if (hide) then
			wnd:hide();
		else
			wnd:show();
		end
	end
end

local function flair_wnd_create(wm, wnd, space, space_active, popup)
	local create = gconfig_get("flair_create");
	if (create_effects and create_effects[create]) then
		display_tiler_action(wm, function()
			create_effects[create](wm, wnd, space, space_active, popup);
		end);
	end
end

-- only menu/config key registration from this point
gconfig_register("flair_drag", "disabled");
gconfig_register("flair_destroy", "disabled");
gconfig_register("flair_create", "disabled");
gconfig_register("flair_hide", "disabled");
gconfig_register("flair_speed", 50);
gconfig_register("flair_drag_opacity", 1.0);

local drag_set = {"disabled"};
if (drag_effects) then
	for k,v in ipairs(drag_effects) do
		table.insert(drag_set, v.label);
	end
end

local create_set = {"disabled"};
if (create_effects) then
	for k,v in pairs(create_effects) do
		table.insert(create_set, k);
	end
end

local destroy_set = {"disabled"};
if (destroy_effects) then
	for k,v in pairs(destroy_effects) do
		table.insert(destroy_set, k);
	end
end

local hide_set = {"disabled"};
if (hide_effects) then
	for k,v in pairs(hide_effects) do
		table.insert(hide_set, k);
	end
end

local flair_config_menu = {
	{
		name = "float_drag",
		label = "Float Drag",
		kind = "value",
		description = "Set the effect that is used 'on window - drag'",
		set = drag_set,
		initial = function()
			return gconfig_get("flair_drag");
		end,
		handler = function(ctx, val)
			gconfig_set("flair_drag", val);
-- account for the value being changed while we're in drag state
			if (drag_effect) then
				drag_effect.stop(active_display().selected);
				drag_effect = nil;
			end
		end
	},
	{
		name = "destroy",
		label = "Destroy",
		kind = "value",
		description = "Set the effect that is used 'on window - destroy'",
		set = destroy_set,
		initial = function()
			return gconfig_get("flair_destroy");
		end,
		handler = function(ctx, val)
			gconfig_set("flair_destroy", val);
		end
	},
	{
		name = "create",
		label = "Create",
		kind = "value",
		description = "Set the effect that is used 'on window - create'",
		set = create_set,
		initial = function()
			return gconfig_get("flair_create");
		end,
		handler = function(ctx, val)
			gconfig_set("flair_create", val);
		end
	},
	{
		name = "hide",
		label = "Hide",
		description = "Set the effect that is used 'on window - hide'",
		kind = "value",
		set = hide_set,
		initial = function()
			return gconfig_get("flair_hide");
		end,
		handler = function(ctx, val)
			gconfig_set("flair_hide", val);
		end
	},
	{
		name = "speed",
		label = "Speed",
		kind = "value",
		description = "Change the relative speed of all flair- related effects",
		initial = function()
			return gconfig_get("flair_speed");
		end,
		validator = gen_valid_num(10, 100),
		handler = function(ctx, val)
			gconfig_set("flair_speed", tonumber(val));
		end
	},
	{
		name = "drag_opacity",
		label = "Drag Opacity",
		description = "Control window opacity when being dragged",
		kind = "value",
		initial = function()
			return gconfig_get("flair_drag_opacity");
		end,
		validator = gen_valid_float(0.1, 1.0),
		handler = function(ctx, val)
			gconfig_set("flair_drag_opacity", tonumber(val));
		end
	}
};

for i,v in ipairs(drag_effects) do
	if (v.menu) then
		table.insert(flair_config_menu, v.menu);
	end
end

local in_flair = false;
local function flair_toggle()
	if (in_flair) then
-- deregister hooks
		in_flair = false;
		for wm in all_tilers_iter() do
			table.remove_match(wm.on_wnd_drag, flair_drag_hook);
			table.remove_match(wm.on_wnd_create, flair_wnd_create);
			table.remove_match(wm.on_wnd_destroy, flair_wnd_destroy);
			table.remove_match(wm.on_wnd_hide, flair_wnd_hide);
		end
	else
		for wm in all_tilers_iter() do
			table.insert(wm.on_wnd_drag, flair_drag_hook);
			table.insert(wm.on_wnd_create, flair_wnd_create);
			table.insert(wm.on_wnd_destroy, flair_wnd_destroy);
			table.insert(wm.on_wnd_hide, flair_wnd_hide);
		end
		in_flair = true;
	end
end

global_menu_register("tools",
{
	name = "flair",
	label = "Flair (toggle)",
	kind = "action",
	description = "Toggle advanced window effects on or off",
	handler = flair_toggle
});

global_menu_register("settings/tools",
{
	name = "flair",
	label = "Flair",
	description = "Change which effects that will be used by the flair tool",
	kind = "action",
	submenu = true,
	handler = flair_config_menu
});