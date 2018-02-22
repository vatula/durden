--
-- Simple VR window manager and image- /model- viewer
--
-- this is written so that it can be wrapped around a small stub loader
-- so that it can be broken out into a separate arcan appl of its own,
-- not needing to piggyback on durden.
--
-- see the use of vrmenus and vrsetup.lua
--

local hmd_arg = "";
local setup_vr = system_load("tools/vrviewer/vrsetup.lua")();

--
-- local function get_valid_windows(cwin, model)
-- 	local lst = {};
-- 	for wnd in all_windows() do
-- 		if (wnd ~= cwin) then
--			local ident = wnd.title_text and wnd.title_text or wnd.name;
--			table.insert(lst, {
--				kind = "action",
--				name = "map_" .. wnd.name,
--				label = "w:" .. ident,
--				eval = function() return valid_vid(cwin.model); end,
--				handler = function()
--					image_sharestorage(wnd.canvas, cwin.model);
--					cwin:set_title(string.format("VR/Panoramic: %s", ident));
--				end
--			});
--		end
--	end
--	return lst;
-- end

local function drag_rotate(ctx, vid, dx, dy)
	rotate3d_model(ctx.wnd.camera, 0, dy, dx, 0, ROTATE_RELATIVE);
end

local function drag_layer(ctx, vid, dx, dy)
	local layer = ctx.wnd.selected_layer;
	if (not layer or layer.fixed) then
		return;
	end

	layer:step(dx, dy);
end

local function vrwnd()
	local preview = alloc_surface(320, 320);

-- and bind to a new window
	local wnd = active_display():add_window(preview, {scalemode = "stretch"});

	if (not wnd) then
		delete_image(preview);
		return;
	end

-- no default symbol bindings
	wnd.bindings = {};
	wnd.clipboard_block = true;
	wnd:set_title(string.format("VR/Panoramic - unmapped"));

-- this will append functions for adding layers and models
	setup_vr(wnd, preview, {});

-- leases that we have taken from the display manager
	wnd.leases = {};

-- make sure that we return the VR displays to the display manager
	wnd:add_handler("destroy",
	function()
		for _,v in ipairs(wnd.leases) do
			display_release(v.name);
		end
	end);

-- if the window gets dragged, resize the context to match
	wnd:add_handler("resize", function(ctx, w, h)
		if (not ctx.in_drag_rz) then
			image_resize_storage(preview, w, h);
			rendertarget_forceupdate(preview);
		end
		resize_image(preview, w, h);
	end);

-- switch mouse handler so canvas drag translates to rotating the camera
	wnd.handlers.mouse.canvas.drag = drag_rotate;
	wnd.handlers.mouse.canvas.wnd = wnd;

	local lst = {};
	for k,v in pairs(wnd.handlers.mouse.canvas) do
		table.insert(lst, k);
	end
	wnd.handlers.mouse.canvas.wnd = wnd;
	mouse_droplistener(wnd.handlers.mouse.canvas);
	mouse_addlistener(wnd.handlers.mouse.canvas, lst);

	show_image(preview);
	wnd.menu_state_disable = true;

-- add window specific menus that expose the real controls
	opts = {
		prefix = "tools/vrviewer/"
	};

	wnd.actions = (system_load("tools/vrviewer/vrmenus.lua")())(wnd, opts);

	table.insert(wnd.actions,
{
	name = "mouse",
	kind = "value",
	description = "Change the current mouse cursor behavior when dragged or locked",
	label = "Mouse",
	set = {"Selected", "View", "Layer Distance"},
	handler = function(ctx, val)
		if (val == "View") then
			wnd.handlers.mouse.canvas.drag = drag_rotate;
		elseif (val == "Layer Distance") then
			wnd.handlers.mouse.canvas.drag = drag_layer;
		end
	end
});

-- add hook to use the browser feature

-- add the full setup command that also leases the display
-- local disp = display_lease(name);
--	if (not disp and not headless) then
--		return;
--	end
-- wnd:message("Spawning VR Bridge");
-- local pipe = wnd:setup_vr();
-- display_release(name);
--

	return wnd;
end

global_menu_register("tools",
{
	name = "vr",
	label = "VR Viewer",
	description = "Panoramic/VR Viewer",
	kind = "action",
-- engine version check
	eval = function() return build_cylinder ~= nil; end,
	handler = vrwnd
});
