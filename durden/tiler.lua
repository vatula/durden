-- Copyright: 2015, Björn Ståhl
-- License: 3-Clause BSD
-- Reference: http://durden.arcan-fe.com
-- Description: Tiler comprise the main tiling window management, event
-- routing, key interpretation and other hooks. It returns a single creation
-- function (tiler_create(W, H)) that returns the usual table of functions and
-- members in pseudo-OO style. Ideally this module should be as free from
-- dependencies to other files as possible to allow the creation of small
-- minimalistic tiling desktop environments.
--

-- number of Z values reserved for each window
local WND_RESERVED = 10;

-- multiply with in point- size to get CM
local FONT_PP_CM = 0.0352778;

system_load("lbar.lua")();

--
-- there is a planned 'effects layer' that reuses the shader API functions
-- for pixman / framebuffer based backends. This layer will (but do not
-- currently) expose a function to set border width and color.
--
assert(SHADER_LANGUAGE == "GLSL120" or SHADER_LANGUAGE == "GLSL100");
local ent_count = 1;
local border_shader = [[
	uniform sampler2D map_diffuse;
	uniform float border;
	uniform float thickness;
	uniform float obj_opacity;
	uniform vec2 obj_output_sz;

	varying vec2 texco;

	void main()
	{
		float margin_s = (border / obj_output_sz.x);
		float margin_t = (border / obj_output_sz.y);
		float margin_w = (thickness / obj_output_sz.x);
		float margin_h = (thickness / obj_output_sz.y);

/* discard both inner and outer border in order to support 'gaps' */
		if (
			( texco.s <= 1.0 - margin_s && texco.s >= margin_s &&
			texco.t <= 1.0 - margin_t && texco.t >= margin_t ) ||
			(
				texco.s < margin_w || texco.t < margin_h ||
				texco.s > 1.0 - margin_w || texco.t > 1.0 - margin_h
			)
		)
			discard;

		gl_FragColor = vec4(texture2D(map_diffuse, texco).rgb, obj_opacity);
	}
]];

-- used for drawing both highlight and background
local tile_shader = [[
uniform float border;
uniform vec3 col_border;
uniform vec3 col_bg;
uniform vec2 obj_output_sz;
varying vec2 texco;

void main()
{
	float bstep_x = border/obj_output_sz.x;
	float bstep_y = border/obj_output_sz.y;

	bvec2 marg1 = greaterThan(texco, vec2(1.0 - bstep_x, 1.0 - bstep_y));
	bvec2 marg2 = lessThan(texco, vec2(bstep_x, bstep_y));
	float f = float( !(any(marg1) || any(marg2)) );

	gl_FragColor = vec4(mix(col_border, col_bg, f), 1.0);
}
]];

-- uised for ignoring alpha to do inherit for visibility but not blendstate
local sbar_shader = [[
uniform sampler2D map_tu0;
varying vec2 texco;
void main()
{
	gl_FragColor = vec4(texture2D(map_tu0, texco).rgba);
}
]];

local tbar_inact_shader = [[
uniform sampler2D map_tu0;
varying vec2 texco;
uniform float obj_opacity;
void main()
{
	gl_FragColor = vec4(vec3(0.5, 0.5, 0.5) *
		texture2D(map_tu0, texco).rgb, obj_opacity);
}
]];

local function build_shaders()
	local bw = gconfig_get("borderw");
	local bt = bw - gconfig_get("bordert");
	local a = build_shader(nil, border_shader, "border_act");
	shader_uniform(a, "border", "f", bw);
	shader_uniform(a, "thickness", "f", bt);

	a = build_shader(nil, border_shader, "border_inact");
	shader_uniform(a, "border", "f", bw);
	shader_uniform(a, "thickness", "f", bt);

	a = build_shader(nil, tile_shader, "tile_act");
	local col = gconfig_get("pcol_act_border");
	shader_uniform(a, "col_border", "fff",
		col[1] / 255.0, col[2] / 255.0, col[3] / 255.0);
	col = gconfig_get("pcol_act_bg");
	shader_uniform(a, "col_bg", "fff",
		col[1] / 255.0, col[2] / 255.0, col[3] / 255.0);
	shader_uniform(a, "border", "f", 1);

	a = build_shader(nil, tile_shader, "tile_alert");
	col = gconfig_get("tcol_alert_border");
	shader_uniform(a, "col_border", "fff",
		col[1] / 255.0, col[2] / 255.0, col[3] / 255.0);
	col = gconfig_get("tcol_alert");
	shader_uniform(a, "col_bg", "fff",
		col[1] / 255.0, col[2] / 255.0, col[3] / 255.0);

	a = build_shader(nil, tile_shader, "tile_inact");
	col = gconfig_get("pcol_bg");
	shader_uniform(a, "col_bg", "fff",
		col[1] / 255.0, col[2] / 255.0, col[3] / 255.0);
	col = gconfig_get("pcol_border");
	shader_uniform(a, "col_border", "fff",
		col[1] / 255.0, col[2] / 255.0, col[3] / 255.0);
	shader_uniform(a, "border", "f", 1);

	a = build_shader(nil, sbar_shader, "sbar_item");
	a = build_shader(nil, tile_shader, "pretile");
	col = gconfig_get("pretile_bg");
	shader_uniform(a, "col_bg", "fff",
		col[1] / 255.0, col[2] / 255.0, col[3] / 255.0);
	col = gconfig_get("pretile_border");
	shader_uniform(a, "col_border", "fff",
		col[1] / 255.0, col[2] / 255.0, col[3] / 255.0);
	shader_uniform(a, "border", "f", 1);

	a = build_shader(nil, tbar_inact_shader, "tbar_inact");
end
build_shaders();

local create_workspace = function() end

local function linearize(wnd)
	local res = {};
	local dive = function(wnd, df)
		if (wnd == nil or wnd.children == nil) then
			return;
		end

		for i,v in ipairs(wnd.children) do
			table.insert(res, v);
			df(v, df);
		end
	end
	dive(wnd, dive);
	return res;
end

local function reorder_space(space)
	for i,v in ipairs(space.wm.windows) do
		if (v.space == space) then
			order_image(v.anchor, i * WND_RESERVED);
		end
	end
end

local function run_event(wnd, event, ...)
	assert(wnd.handlers[event]);
	for i,v in ipairs(wnd.handlers[event]) do
		v(wnd, unpack({...}));
	end
end

local function wnd_destroy(wnd)
	local wm = wnd.wm;
	if (wm.debug_console) then
		wm.debug_console:system_event("lost " .. wnd.name);
	end

	if (wm.selected == wnd) then
		wnd:deselect();
		local mx, my = mouse_xy();
	end

	if (wnd.fullscreen) then
		wnd.space:tile();
	end

	if (wnd.mouse_handler) then
		mouse_droplistener(wnd.mouse_handler);
	end

-- mark a new node as selected
	if (#wnd.children > 0) then
		wnd.children[1]:select();
	elseif (wnd.parent and wnd.parent.parent) then
		wnd.parent:select();
	else
		wnd:prev();
	end

-- but that doesn't always succeed (edge-case, last window)
	if (wnd.wm.selected == wnd) then
		wnd.wm.selected = nil;
		if (wnd.space.selected == wnd) then
		wnd.space.selected = nil;
		end
	end

-- re-assign all children to parent
	for i,v in ipairs(wnd.children) do
		table.insert(wnd.parent.children, v);
		v.parent = wnd.parent;
	end

-- now we can run destroy hooks
	run_event(wnd, "destroy");
	for i,v in ipairs(wnd.relatives) do
		run_event(v, "lost_relative", wnd);
	end

-- drop references, cascade delete from anchor
	delete_image(wnd.anchor);
	table.remove_match(wnd.parent.children, wnd);

	for i=1,10 do
		if (wm.spaces[i] and wm.spaces[i].selected == wnd) then
			wm.spaces[i].selected = nil;
		end

		if (wm.spaces[i] and wm.spaces[i].previous == wnd) then
			wm.spaces[i].previous = nil;
		end
	end

-- in tabbed mode, titlebar is not linked to the anchor and
-- won't cascade down, so to not leak a vid, drop it here
	if (valid_vid(wnd.titlebar)) then
		delete_image(wnd.titlebar);
	end

	local space = wnd.space;
	for k,v in pairs(wnd) do
		wnd[k] = nil;
	end

-- drop global tracking
	table.remove_match(wm.windows, wnd);

-- rebuild layout
	space:resize();
end

local function wnd_message(wnd, message, timeout)
	print(message);
end

local function wnd_deselect(wnd)
	local mwm = wnd.space.mode;
	if (mwm == "tab" or mwm == "vtab") then
		hide_image(wnd.anchor);
	end

	if (wnd.wm.selected == wnd) then
		wnd.wm.selected = nil;
	end

	if (wnd.mouse_lock) then
		mouse_lockto(BADID);
	end

	wnd:set_dispmask(bit.bor(wnd.dispmask, TD_HINT_UNFOCUSED));

	local x, y = mouse_xy();
	if (image_hit(wnd.canvas, x, y) and wnd.cursor == "hidden") then
		mouse_show();
	end

	image_shader(wnd.border, "border_inact");
	image_shader(wnd.titlebar, "tbar_inact");
	image_sharestorage(wnd.wm.border_color, wnd.border);

-- save scaled coordinates so we can handle a resize
	if (gconfig_get("mouse_remember_position")) then
		local props = image_surface_resolve_properties(wnd.canvas);
		if (x >= props.x and y >= props.y and
			x <= props.x + props.width and y <= props.y + props.height) then
			wnd.mouse = {
				(x - props.x) / props.width,
				(y - props.y) / props.height
			};
		end
	end

	run_event(wnd, "deselect");
end

local function gen_status_tile(wm, lbl, min_sz, ofs)
	local text = render_text(lbl);
	local props = image_surface_properties(text);
	local yp = gconfig_get("sbar_pad") + math.floor(0.5 * (min_sz - props.height));

	if (props.width < min_sz) then
		move_image(text, math.floor(0.5*(min_sz - props.width)), yp);
	else
		move_image(text, gconfig_get("sbar_pad"), yp);
	end

	local tilew = (props.width+4) > min_sz and (props.width+4) or min_sz;
	local tile = fill_surface(tilew, min_sz, 255, 255, 255);
	link_image(text, tile);
	show_image({text, tile});
	image_mask_set(text, MASK_UNPICKABLE);
	image_inherit_order(tile, true);
	image_inherit_order(text, true);
	link_image(tile, wm.statusbar);
	image_tracetag(text, "tiler_sbar_tile");
	image_shader(text, "sbar_item");

	move_image(tile, ofs, 0);
	ofs = ofs + tilew + 1;
	return tile, ofs;
end

local function output_mouse_devent(btl, wnd)
	btl.kind = "digital";
	btl.source = "mouse";

-- rate limit is used to align input event storms (likely to cause visual
-- changes that need synchronization) with the logic ticks (where the engine
-- is typically not processing rendering), and to provent the horrible
-- spikes etc. that can come with high-samplerate.
	if (not wnd.rate_unlimited) then
		local wndq = EVENT_SYNCH[wnd.external];
		if (wndq and (wndq.pending and #wndq.pending > 0)) then
			table.insert(wndq.queue, wndq.pending[1]);
			table.insert(wndq.queue, wndq.pending[2]);
			table.insert(wndq.queue, btl);
			wndq.pending = nil;
			return;
		end
	end

	if (btl == nil) then
		print(debug.traceback());
	end
	target_input(wnd.external, btl);
end

-- statusbar is divided into three areas:
-- first,  [pre-tiles]
-- second, [workspace-tiles]
-- third,  message [cropped to fill] + timeout
-- fourth, statusbar vid (will take ownership)
local function tiler_statusbar_update(wm, pretiles, msg, timeout, sbar)
	local statush = gconfig_get("sbar_sz");
	resize_image(wm.statusbar, wm.width, statush);
	move_image(wm.statusbar, 0, wm.height - statush);

	if(wm.spaces[wm.space_ind].mode == "fullscreen") then
		hide_image(wm.statusbar);
	else
		blend_image(wm.statusbar, gconfig_get("sbar_alpha"));
	end
	local ofs = 0;

-- pretiles for various status indicators, if we mark the set for update:
	if (pretiles) then
		if (wm.pretiles) then
			for k,v in ipairs(wm.pretiles) do
				if (valid_vid(v)) then delete_image(v); end
			end
		end
		wm.pretiles = {};
		for k,v in ipairs(pretiles) do
			local text = string.format("%s%s %s",
				gconfig_get("font_str"), gconfig_get("pretiletext_color"), v);
			local pret;
			pret, ofs = gen_status_tile(wm, text, statush, ofs);
			if (valid_vid(pret)) then
				table.insert(wm.pretiles, pret);
				image_shader(pret, "pretile");
			end
		end
-- just slide the offset for re-use
	else
		if (wm.pretiles) then
			for k,v in ipairs(wm.pretiles) do
				move_image(v, ofs, 0);
				ofs = ofs + image_surface_properties(v).width + 1;
			end
		end
	end
-- and set ws
	for i=1,10 do
		if (wm.spaces[i] ~= nil) then
			local space = wm.spaces[i];
			if (space.label_id == nil) then
				local text = string.format("%s%s %d%s",
					gconfig_get("font_str"), gconfig_get("text_color"), i,
					space.label ~= nil and (":" .. gconfig_get("label_color") .. " " ..
					space.label) or "");
				space.label_id, ofs = gen_status_tile(wm, text, statush, ofs);
			else
				move_image(space.label_id, ofs, 0);
				ofs = ofs + image_surface_properties(space.label_id).width + 1;
			end

			image_shader(space.label_id,
				i == wm.space_ind and "tile_act" or "tile_inact");

			space.tile_ml = {
				own = function(ctx, vid, event)
					return vid == space.label_id;
				end,
				click = function(ctx, vid, event)
					wm:switch_ws(i);
				end,
				rclick = click,
				name = "tile_ml_" .. tostring(i)
			};
			mouse_addlistener(space.tile_ml, {"click", "rclick"});
		end
	end

-- update statusbar vid?
--
--			local props = image_surface_properties(wm.statusbar_msg);
--			local xpos = wm.width - props.width;

-- align to 40px just to lessen the effect of non-monospace font
--			if (xpos % 40 ~= 0) then
--				xpos = xpos - (xpos % 40);
--			end
--			xpos = xpos < ofs and ofs or xpos;
--			move_image(wm.statusbar_msg, xpos, 3);
--		end
--	end

-- add msg in statusbar "slot", protect against overflow into ws list
	if (msg ~= nil) then
		local text = {gconfig_get("sbar_textstr"), msg};
		if (valid_vid(wm.statusbar_msg)) then
			render_text(wm.statusbar_msg, text);
		else
			wm.statusbar_msg = render_text(text);
			show_image(wm.statusbar_msg);
			image_inherit_order(wm.statusbar_msg, true);
			link_image(wm.statusbar_msg, wm.statusbar);
			image_shader(wm.statusbar_msg, "sbar_item");
			move_image(wm.statusbar_msg, ofs, 1);
		end

		if (timeout and timeout > 0 and valid_vid(wm.statusbar_msg)) then
			expire_image(wm.statusbar_msg, timeout);
		end
	end
end

local function tile_upd(wm)
	local space = wm.spaces[wm.space_ind];
	local im = space.insert == "horizontal" and "horiz" or "vert";

	wm:update_statusbar({
		space.mode .. (space.mode == "tile" and (":" .. im) or "")
	});
end

local function tiler_statusbar_invalidate(wm)
	if (wm.pretiles) then
		for k,v in ipairs(wm.pretiles) do
			if (valid_vid(v)) then
				delete_image(v);
			end
		end
		wm.pretiles = nil;
	end

	for i=1,10 do
		if (wm.spaces[i] ~= nil) then
			local space = wm.spaces[i];
			if (valid_vid(space.label_id)) then
				delete_image(space.label_id);
				space.label_id = nil;
			end
		end
	end

	tile_upd(wm);
end

-- we need an overlay anchor that is only used for ordering, this to handle
-- that windows may appear while the overlay is active
local function wm_order(wm)
	return wm.order_anchor;
end
-- recursively resolve the relation hierarchy and return a list
-- of vids that are linked to a specific vid
local function get_hier(vid)
	local ht = {};

	local level = function(hf, vid)
		for i,v in ipairs(image_children(vid)) do
			table.insert(ht, v);
			hf(hf, v);
		end
	end

	level(level, vid);
	return ht;
end

local function wnd_select(wnd, source)
	if (not wnd.wm) then
		warning("select on broken window");
		print(debug.traceback());
		return;
	end

-- may be used to reactivate locking after a lbar or similar action
-- has been performed.
	if (wnd.wm.selected == wnd) then
		if (wnd.mouse_lock) then
			mouse_lockto(wnd.canvas, type(wnd.mouse_lock) == "function" and
				wnd.mouse_lock or nil);
		end
		return;
	end

	wnd:set_dispmask(bit.band(wnd.dispmask,
		bit.bnot(wnd.dispmask, TD_HINT_UNFOCUSED)));

	if (wnd.wm.selected) then
		wnd.wm.selected:deselect();
	end

	local mwm = wnd.space.mode;
	if (mwm == "tab" or mwm == "vtab") then
		show_image(wnd.anchor);
	end

	image_shader(wnd.border, "border_act");
	image_shader(wnd.titlebar, "DEFAULT");
	image_sharestorage(wnd.wm.active_border_color, wnd.border);
	run_event(wnd, "select");
	wnd.space.previous = wnd.space.selected;
	wnd.wm.selected = wnd;
	wnd.space.selected = wnd;

	ms = mouse_state();
	ms.hover_ign = true;
	local mouse_moved = false;
	local props = image_surface_resolve_properties(wnd.canvas);
	if (gconfig_get("mouse_remember_position") and not ms.in_handler) then
		local px = 0.0;
		local py = 0.0;

		if (wnd.mouse) then
			px = wnd.mouse[1];
			py = wnd.mouse[2];
		end
		mouse_absinput(props.x + px * props.width, props.y + py * props.height);
		mouse_moved = true;
	end
	mouse_state().last_hover = CLOCK;
	mouse_state().hover_ign = false;

	if (wnd.mouse_lock) then
		mouse_lockto(wnd.canvas, type(wnd.mouse_lock) == "function" and
				wnd.mouse_lock or nil);
	end
end

--
-- This is _the_ operation when it comes to window management here, it resizes
-- the actual size of a tile (which may not necessarily match the size of the
-- underlying surface). Keep everything divisible by two for simplicity.
--
-- The overall structure in split mode is simply a tree, split resources fairly
-- between individuals (with an assignable weight) and recurse down to children
--
local function level_resize(level, x, y, w, h, node)
	local fair = math.ceil(w / #level.children);
	fair = (fair % 2) == 0 and fair or fair + 1;

	if (#level.children == 0) then
		return;
	end

	local process_node = function(node, last)
		node.x = x; node.y = y;
		node.h = h;

		if (last) then
			node.w = w;
		else
			node.w = math.ceil(fair * node.weight);
			node.w = (node.w % 2) == 0 and node.w or node.w + 1;
		end

		if (#node.children > 0) then
			node.h = math.ceil(h / 2 * node.vweight);
			node.h = (node.h % 2) == 0 and node.h or node.h + 1;
			level_resize(node, x, y + node.h, node.w, h - node.h);
		end

		node:resize(node.w, node.h);
		move_image(node.anchor, node.x, node.y);

		x = x + node.w;
		w = w - node.w;
	end

	for i=1,#level.children-1 do
		process_node(level.children[i]);
	end

	process_node(level.children[#level.children], true);
end

local function workspace_activate(space, noanim, negdir, newbg)
	local time = gconfig_get("transition");
	local method = gconfig_get("ws_transition_in");

-- wake any sleeping windows up and make sure it knows it if is selected or not
	for k,v in ipairs(space.wm.windows) do
		if (v.space == space) then
			v:set_dispmask(bit.band(v.dispmask, bit.bnot(TD_HINT_INVISIBLE)), true);
			if (space.selected ~= v) then
				v:set_dispmask(bit.bor(v.dispmask, TD_HINT_UNFOCUSED));
			else
				v:set_dispmask(bit.band(v.dispmask, bit.bnot(TD_HINT_UNFOCUSED)));
			end
		end
	end

	if (not noanim and time > 0 and method ~= "none") then
		if (method == "move-h") then
			move_image(space.anchor, (negdir and -1 or 1) * space.wm.width, 0);
			move_image(space.anchor, 0, 0, time);
			show_image(space.anchor);
		elseif (method == "move-v") then
			move_image(space.anchor, 0, (negdir and -1 or 1) * space.wm.height);
			move_image(space.anchor, 0, 0, time);
			show_image(space.anchor);
		elseif (method == "fade") then
			move_image(space.anchor, 0, 0);
-- stay at level zero for a little while so not to fight with crossfade
			blend_image(space.anchor, 0.0, 0.5 * time);
			blend_image(space.anchor, 1.0, 0.5 * time);
		else
			warning("broken method set for ws_transition_in: " ..method);
		end
-- slightly more complicated, we don't want transitions if the background is the
-- same between different workspaces as it is visually more distracting
		local bg = space.background;
		if (bg) then
			if (not valid_vid(newbg) or not image_matchstorage(newbg, bg)) then
				instant_image_transform(bg);
				blend_image(bg, 0.0, time);
				blend_image(bg, 1.0, time);
				image_mask_set(bg, MASK_POSITION);
				image_mask_set(bg, MASK_OPACITY);
			else
				show_image(bg);
				image_mask_clear(bg, MASK_POSITION);
				image_mask_clear(bg, MASK_OPACITY);
			end
		end
	else
		show_image(space.anchor);
		if (space.background) then show_image(space.background); end
	end

	local tgt = space.selected and space.selected or space.children[1];
end

local function workspace_deactivate(space, noanim, negdir, newbg)
	local time = gconfig_get("transition");
	local method = gconfig_get("ws_transition_out");

-- notify windows that they can take things slow
	for k,v in ipairs(space.wm.windows) do
		if (v.space == space) then
			if (valid_vid(v.external, TYPE_FRAMESERVER)) then
				v:set_dispmask(bit.bor(v.dispmask, TD_HINT_INVISIBLE));
				target_displayhint(v.external, 0, 0, v.dispmask);
			end
		end
	end

	if (not noanim and time > 0 and method ~= "none") then
		if (method == "move-h") then
			move_image(space.anchor, (negdir and -1 or 1) * space.wm.width, 0, time);
		elseif (method == "move-v") then
			move_image(space.anchor, 0, (negdir and -1 or 1) * space.wm.height, time);
		elseif (method == "fade") then
			blend_image(space.anchor, 0.0, 0.5 * time);
		else
			warning("broken method set for ws_transition_out: "..method);
		end
		local bg = space.background;
		if (bg) then
			if (not valid_vid(newbg) or not image_matchstorage(newbg, bg)) then
				blend_image(bg, 0.0, 0.25 * time);
				image_mask_set(bg, MASK_POSITION);
				image_mask_set(bg, MASK_OPACITY);
			else
				hide_image(bg);
				image_mask_clear(bg, MASK_POSITION);
				image_mask_clear(bg, MASK_OPACITY);
			end
		end
	else
		hide_image(space.anchor);
		if (valid_vid(space.background)) then
			hide_image(space.background);
		end
	end
end

-- migrate window means:
-- copy valuable properties, destroy then "add", including tiler.windows
local function workspace_migrate(ws, newt)
	local oldt = ws.wm;
	if (oldt == display) then
		return;
	end

-- find a free slot and locate the source slot
	local dsti;
	for i=1,10 do
		if (newt.spaces[i] == nil or (
			#newt.spaces[i].children == 0 and newt.spaces[i].label == nil)) then
			dsti = i;
			break;
		end
	end

	local srci;
	for i=1,10 do
		if (oldt.spaces[i] == ws) then
			srci = i;
			break;
		end
	end

	if (not dsti or not srci) then
		return;
	end

-- add/remove from corresponding tilers, update status bars
	workspace_deactivate(ws, true);
	ws.wm = newt;
	rendertarget_attach(newt.rtgt_id, ws.anchor, RENDERTARGET_DETACH);
	link_image(ws.anchor, newt.anchor);

	local wnd = linearize(ws);
	for i,v in ipairs(wnd) do
		v.wm = newt;
		table.insert(newt.windows, v);
		table.remove_match(oldt.windows, v);
	end
	oldt.spaces[srci] = create_workspace(oldt, false);

-- switch rendertargets
	local list = get_hier(ws.anchor);
	for i,v in ipairs(list) do
		rendertarget_attach(newt.rtgt_id, v, RENDERTARGET_DETACH);
	end

	if (dsti == newt.space_ind) then
		workspace_activate(ws, true);
		newt.selected = oldt.selected;
	end

	oldt.selected = nil;

	order_image(oldt.order_anchor,
		2 + #oldt.windows * WND_RESERVED + 2 * WND_RESERVED);
	order_image(newt.order_anchor,
		2 + #newt.windows * WND_RESERVED + 2 * WND_RESERVED);

	newt.spaces[dsti] = ws;

	local olddisp = active_display();
	set_context_attachment(newt.rtgt_id);
	ws:resize();
	if (valid_vid(ws.label_id)) then
		delete_image(ws.label_id);
		mouse_droplistener(ws.tile_ml);
		ws.label_id = nil;
	end
	newt:update_statusbar();

	set_context_attachment(olddisp.rtgt_id);
	oldt:update_statusbar();
end

-- undo / redo the effect that deselect will hide the active window
local function switch_tab(space, to, ndir)
	local wnds = linearize(space);
	if (to) then
		for k,v in ipairs(wnds) do
			hide_image(v.anchor);
		end
		workspace_activate(space, false, ndir);
	else
		for k,v in ipairs(wnds) do
			show_image(v.anchor);
		end
		workspace_deactivate(space, false, ndir);
	end
end

local function switch_fullscreen(space, to, ndir)
	if (space.selected == nil) then
		return;
	end

	if (to) then
		hide_image(space.wm.statusbar);
		workspace_activate(space, false, ndir);
		local lst = linearize(space);
		for k,v in ipairs(space) do
			hide_image(space.anchor);
		end
		show_image(space.selected.anchor);
	else
		show_image(space.wm.statusbar);
		workspace_deactivate(space, false, ndir);
	end
end

local function drop_fullscreen(space, swap)
	workspace_activate(space, true);
	show_image(space.wm.statusbar);

	if (not space.selected) then
		return;
	end

	local wnds = linearize(space);
	for k,v in ipairs(wnds) do
		show_image(v.anchor);
	end

	local dw = space.selected;
	show_image(dw.titlebar);
	show_image(dw.border);
	dw.fullscreen = nil;
	image_mask_set(dw.canvas, MASK_OPACITY);
	space.switch_hook = nil;
end

local function drop_tab(space)
	local res = linearize(space);
-- new mode will resize so don't worry about that, just relink
	for k,v in ipairs(res) do
		link_image(v.titlebar, v.anchor);
		order_image(v.titlebar, 2);
		show_image(v.border);
		show_image(v.anchor);
		move_image(v.titlebar, v.border_w, v.border_w);
	end

	space.mode_hook = nil;
	space.switch_hook = nil;
	space.reassign_hook = nil;
end

local function drop_float(space, swap)
	space.in_float = false;

	local lst = linearize(space);
	for i,v in ipairs(lst) do
		local pos = image_surface_properties(v.anchor);
		v.last_float = {
			width = v.width,
			height = v.height,
			x = pos.x,
			y = pos.y
		};
	end

	reorder_space(space);
end

local function reassign_float(space, wnd)
end

local function reassign_tab(space, wnd)
	link_image(wnd.titlebar, wnd.anchor);
	order_image(wnd.titlebar, 2);
	move_image(wnd.titlebar, wnd.border_w, wnd.border_w);
	show_image(wnd.anchor);
end

-- just unlink statusbar, resize all at the same time (also hides some
-- of the latency in clients producing new output buffers with the correct
-- dimensions etc). then line the statusbars at the top.
local function set_tab(space)
	local lst = linearize(space);
	if (#lst == 0) then
		return;
	end

	space.mode_hook = drop_tab;
	space.switch_hook = switch_tab;
	space.reassign_hook = reassign_tab;

	local fairw = math.ceil(space.wm.width / #lst);
	local tbar_sz = gconfig_get("tbar_sz");
	local bw = gconfig_get("borderw");
	local ofs = 0;

	for k,v in ipairs(lst) do
		v:resize_effective(space.wm.width,
			space.wm.height - gconfig_get("sbar_sz") - tbar_sz);
		move_image(v.anchor, 0, 0);
		move_image(v.canvas, 0, tbar_sz);
		hide_image(v.anchor);
		hide_image(v.border);
		link_image(v.titlebar, space.anchor);
		order_image(v.titlebar, 2);
		move_image(v.titlebar, ofs, 0);
		resize_image(v.titlebar, fairw, tbar_sz);
		ofs = ofs + fairw;
	end

	if (space.selected) then
		local wnd = space.selected;
		wnd:deselect();
		wnd:select();
	end
end

-- tab and vtab are similar in most aspects except for the axis used
-- and the re-ordering of the selected statusbar
local function set_vtab(space)
	local lst = linearize(space);
	if (#lst == 0) then
		return;
	end

	space.mode_hook = drop_tab;
	space.switch_hook = nil; -- switch_tab;
	space.reassign_hook = reassign_tab;

	local tbar_sz = gconfig_get("tbar_sz");
	local ypos = #lst * tbar_sz;
	local cl_area = space.wm.height -
		gconfig_get("sbar_sz") - ypos - 2 * gconfig_get("borderw");
	if (cl_area < 1) then
		return;
	end

	local ofs = 0;
	for k,v in ipairs(lst) do
		v:resize_effective(space.wm.width, cl_area);
		move_image(v.anchor, 0, ypos);
		move_image(v.canvas, 0, 0);
		hide_image(v.anchor);
		hide_image(v.border);
		link_image(v.titlebar, space.anchor);
		order_image(v.titlebar, 2);
		resize_image(v.titlebar, space.wm.width, tbar_sz);
		move_image(v.titlebar, 0, (k-1) * tbar_sz);
		ofs = ofs + tbar_sz;
	end

	if (space.selected) then
		local wnd = space.selected;
		wnd:deselect();
		wnd:select();
	end
end

local function set_fullscreen(space)
	if (not space.selected) then
		return;
	end
	local dw = space.selected;

-- hide all images + statusbar
	hide_image(dw.wm.statusbar);
	local wnds = linearize(space);
	for k,v in ipairs(wnds) do
		hide_image(v.anchor);
	end
	show_image(dw.anchor);
	hide_image(dw.titlebar);
	hide_image(space.selected.border);

	dw.fullscreen = true;
	space.mode_hook = drop_fullscreen;
	space.switch_hook = switch_fullscreen;

	dw:resize(dw.wm.width, dw.wm.height);
	move_image(dw.anchor, 0, 0);
end

local function set_float(space)
	if (not space.in_float) then
		space.in_float = true;
		space.reassign_hook = reassign_float;
		space.mode_hook = drop_float;
		local tbl = linearize(space);
		for i,v in ipairs(tbl) do
			local props = image_storage_properties(v.canvas);
			local neww;
			local newh;

			if (v.last_float) then
				neww = v.last_float.width;
				newh = v.last_float.height;
				move_image(v.anchor, v.last_float.x, v.last_float.y);
			else
				neww = props.width + v.pad_left + v.pad_right;
				newh = props.height + v.pad_top + v.pad_bottom;
			end

			v:resize(neww, newh, true);
		end
	end
end

local function set_tile(space)
	show_image(space.wm.statusbar);
	level_resize(space, 0, 0, space.wm.width,
		space.wm.height - gconfig_get("sbar_sz") - 1);
end

local space_handlers = {
	tile = set_tile,
	float = set_float,
	fullscreen = set_fullscreen,
	tab = set_tab,
	vtab = set_vtab
};

local function workspace_destroy(space)
	if (space.mode_hook) then
		space:mode_hook();
		space.mode_hook = nil;
	end

	while (#space.children > 0) do
		space.children[1]:destroy();
	end

	if (valid_vid(space.rtgt_id)) then
		delete_image(space.rtgt_id);
	end

	if (space.label_id ~= nil) then
		delete_image(space.label_id);
	end

	if (space.background) then
		delete_image(space.background);
	end

	delete_image(space.anchor);
	for k,v in pairs(space) do
		space[k] = nil;
	end
end

local function workspace_set(space, mode)
	if (space_handlers[mode] == nil or mode == space.mode) then
		return;
	end

-- cleanup to revert to the normal stable state (tiled)
	if (space.mode_hook) then
		space:mode_hook();
		space.mode_hook = nil;
	end

-- for float, first reset to tile then switch to get a fair distribution
-- another option would be to first set their storage dimensions and then
-- force
	if (mode == "float" and space.mode ~= "tile") then
		space.mode = "tile";
		space:resize();
	end

	space.mode = mode;
	space:resize();
	tiler_statusbar_update(space.wm, {mode});
end

local function workspace_resize(space)
	if (space_handlers[space.mode]) then
		space_handlers[space.mode](space, true);
	end

	if (valid_vid(space.background)) then
		resize_image(space.background, space.wm.width, space.wm.height);
	end
end

local function workspace_label(space, lbl)
	if (valid_vid(space.label_id)) then
		delete_image(space.label_id);
		space.label_id = nil;
	end
	space.label = lbl;
	space.wm:update_statusbar();
end

local function workspace_empty(wm, i)
	return (wm.spaces[i] == nil or
		(#wm.spaces[i].children == 0 and wm.spaces[i].label == nil));
end

local function workspace_save(ws, shallow)

	local ind;
	for k,v in pairs(ws.wm.spaces) do
		if (v == ws) then
			ind = k;
		end
	end

	assert(ind ~= nil);

	local keys = {};
	local prefix = string.format("wsk_%s_%d", ws.wm.name, ind);
	keys[prefix .. "_mode"] = ws.mode;
	keys[prefix .. "_insert"] = ws.insert;
	if (ws.label) then
		keys[prefix .."_label"] = ws.label;
	end

	if (ws.background_name) then
		keys[prefix .. "_bg"] = ws.background_name;
	end

	drop_keys(prefix .. "%");
	store_key(keys);

	if (shallow) then
		return;
	end
-- depth serialization and metastructure missing
end

local function workspace_background(ws, bgsrc, generalize)
	local new_vid = function(src)
		if (not valid_vid(ws.background)) then
			ws.background = null_surface(ws.wm.width, ws.wm.height);
			image_shader(ws.background, shader_getkey("noalpha"));
		end
		resize_image(ws.background, ws.wm.width, ws.wm.height);
		link_image(ws.background, ws.anchor);
		show_image(ws.background);
		if (valid_vid(src)) then
			image_sharestorage(src, ws.background);
		end
	end

	if (bgsrc == nil) then
		if (valid_vid(ws.background)) then
			delete_image(ws.background);
			ws.background = nil;
			ws.background_name = nil;
		end
	elseif (type(bgsrc) == "string") then
		local vid = load_image_asynch(bgsrc, function(src, stat)
			if (stat.kind == "loaded") then
			ws.background_name = bgsrc;
			new_vid(src);
			delete_image(src);
			if (generalize) then
				ws.wm.background_name = bgsrc;
				store_key(string.format("ws_%s_bg", ws.wm.name), bgsrc);
			end
		else
			delete_image(src);
		end
	end);
		new_vid(vid);
	elseif (type(bgsrc) == "number" and valid_vid(bgsrc)) then
		new_vid(bgsrc);
		ws.background_name = nil;
	else
		warning("workspace_background - called with invalid. arg");
	end
end

create_workspace = function(wm, anim)
	local res = {
		activate = workspace_activate,
		deactivate = workspace_deactivate,
		resize = workspace_resize,
		destroy = workspace_destroy,
		migrate = workspace_migrate,
		save = workspace_save,

-- different layout modes, patch here and workspace_set to add more
		fullscreen = function(ws) workspace_set(ws, "fullscreen"); end,
		tile = function(ws) workspace_set(ws, "tile"); end,
		tab = function(ws) workspace_set(ws, "tab"); end,
		vtab = function(ws) workspace_set(ws, "vtab"); end,
		float = function(ws) workspace_set(ws, "float"); end,

		set_label = workspace_label,
		set_background = workspace_background,

-- can be used for clipping / transitions
		anchor = null_surface(wm.width, wm.height),
		mode = "tile",
		name = "workspace_" .. tostring(ent_count);
		insert = "horizontal",
		children = {},
		weight = 1.0,
		vweight = 1.0
	};
	image_tracetag(res.anchor, "workspace_anchor");
	show_image(res.anchor);
	link_image(res.anchor, wm.anchor);
	ent_count = ent_count + 1;
	res.wm = wm;
	workspace_set(res, gconfig_get("ws_default"));
	if (wm.background_name) then
		res:set_background(wm.background_name);
	end
	res:activate(anim);
	return res;
end

local function wnd_merge(wnd)
	local i = 1;
	while (i ~= #wnd.parent.children) do
		if (wnd.parent.children[i] == wnd) then
			break;
		end
		i = i + 1;
	end

	if (i < #wnd.parent.children) then
		for j=i+1,#wnd.parent.children do
			table.insert(wnd.children, wnd.parent.children[j]);
			wnd.parent.children[j].parent = wnd;
		end
		for j=#wnd.parent.children,i+1,-1 do
			table.remove(wnd.parent.children, j);
		end
	end

	wnd.space:resize();
end

local function wnd_collapse(wnd)
	for k,v in ipairs(wnd.children) do
		table.insert(wnd.parent.children, v);
		v.parent = wnd.parent;
	end
	wnd.children = {};
	wnd.space:resize();
end

local function apply_scalemode(wnd, mode, src, props, maxw, maxh, force)
	local outw = 1;
	local outh = 1;

	if (wnd.scalemode == "normal" and not force) then
-- explore: modify texture coordinates and provide scrollbars
		if (props.width > 0 and props.height > 0) then
			outw = props.width < maxw and props.width or maxw;
			outh = props.height < maxh and props.height or maxh;
		end

	elseif (force or wnd.scalemode == "stretch") then
		outw = maxw;
		outh = maxh;

	elseif (wnd.scalemode == "aspect") then
		local ar = props.width / props.height;
		local wr = props.width / maxw;
		local hr = props.height/ maxh;

		outw = hr > wr and math.ceil(maxh * ar - 0.5) or maxw;
		outh = hr < wr and math.ceil(maxw / ar - 0.5) or maxh;
	end

	resize_image(src, outw, outh);
	if (wnd.autocrop) then
		local ip = image_storage_properties(src);
		image_set_txcos_default(src);
		image_scale_txcos(src, outw / ip.width, outh / ip.height);
	end
	if (wnd.filtermode) then
		image_texfilter(src, wnd.filtermode);
	end
	return outw, outh;
end

local function wnd_effective_resize(wnd, neww, newh, force)
	wnd:resize(neww + wnd.pad_left + wnd.pad_right,
		newh + wnd.pad_top + wnd.pad_bottom);
end

local function wnd_font(wnd, sz, hint, font)
	if (valid_vid(wnd.external, TYPE_FRAMESERVER)) then
		if (font) then
			target_fonthint(wnd.external, font, sz * FONT_PP_CM, hint);
		else
			target_fonthint(wnd.external, sz * FONT_PP_CM, hint);
		end
	end
end

local function wnd_resize(wnd, neww, newh, force)
	neww = wnd.wm.min_width > neww and wnd.wm.min_width or neww;
	newh = wnd.wm.min_height > newh and wnd.wm.min_height or newh;

	resize_image(wnd.anchor, neww, newh);
	resize_image(wnd.border, neww, newh);

	resize_image(wnd.titlebar, neww - wnd.border_w * 2,
		image_surface_properties(wnd.titlebar).height);

	wnd.width = neww;
	wnd.height = newh;

	local props = image_storage_properties(wnd.canvas);

	if (wnd.wm.debug_console) then
		wnd.wm.debug_console:system_event(string.format("%s%s resized to %d, %d",
			wnd.name, force and " force" or "", neww, newh));
	end

-- to save space for border width, statusbar and other properties
	if (not wnd.fullscreen) then
		move_image(wnd.canvas, wnd.pad_left, wnd.pad_top);
		neww = neww - wnd.pad_left - wnd.pad_right;
		newh = newh - wnd.pad_top - wnd.pad_bottom;
	else
		move_image(wnd.canvas, 0, 0);
	end

	if (neww <= 0 or newh <= 0) then
		return;
	end

	wnd.effective_w = neww;
	wnd.effective_h = newh;

	wnd.effective_w, wnd.effective_h = apply_scalemode(wnd,
		wnd.scalemode, wnd.canvas, props, neww, newh, wnd.space.mode == "float");

	if (wnd.centered) then
		move_image(wnd.anchor, math.floor(0.5*(neww - wnd.effective_w)),
			math.floor(0.5*(newh - wnd.effective_h)));
	end

	run_event(wnd, "resize", neww, newh, wnd.effective_w, wnd.effective_h);
end

local function wnd_next(mw, level)
	if (mw.fullscreen) then
		return;
	end

-- we use three states; true, false or nil.
	local mwm = mw.space.mode;
	if (mwm == "tab" or mwm == "vtab" or mwm == "float") then
		local lst = linearize(mw.space);
		local ind = table.find_i(lst, mw);
		ind = ind == #lst and 1 or ind + 1;
		lst[ind]:select();
		return;
	end

	if (level) then
		if (#mw.children > 0) then
			mw.children[1]:select();
			return;
		end
	end

	local i = 1;
	while (i < #mw.parent.children) do
		if (mw.parent.children[i] == mw) then
			break;
		end
		i = i + 1;
	end

	if (i == #mw.parent.children) then
		if (mw.parent.parent ~= nil) then
			return wnd_next(mw.parent, false);
		else
			i = 1;
		end
	else
		i = i + 1;
	end

	mw.parent.children[i]:select();
end

local function wnd_prev(mw, level)
	if (mw.fullscreen) then
		return;
	end

	local mwm = mw.space.mode;
	if (mwm == "tab" or mwm == "vtab" or mwm == "float") then
		local lst = linearize(mw.space);
		local ind = table.find_i(lst, mw);
		ind = ind == 1 and #lst or ind - 1;
		lst[ind]:select();
		return;
	end

	if (level or mwm == "tab" or mwm == "vtab") then
		if (mw.parent.select) then
			mw.parent:select();
			return;
		end
	end

	local ind = 1;
	for i,v in ipairs(mw.parent.children) do
		if (v == mw) then
			ind = i;
			break;
		end
	end

	if (ind == 1) then
		if (mw.parent.parent) then
			mw.parent:select();
		else
			mw.parent.children[#mw.parent.children]:select();
		end
	else
		ind = ind - 1;
		mw.parent.children[ind]:select();
	end
end

local function wnd_reassign(wnd, ind, ninv)
-- for reassign by name, resolve to index
	local newspace = nil;

	if (type(ind) == "string") then
		for k,v in pairs(wnd.wm.spaces) do
			if (v.label == ind) then
				ind = k;
			end
		end
		if (type(ind) == "string") then
			return;
		end
		newspace = wnd.wm.spaces[ind];
	elseif (type(ind) == "table") then
		newspace = ind;
	else
		newspace = wnd.wm.spaces[ind];
	end

-- don't switch unless necessary
	if (wnd.space == newspace or wnd.fullscreen) then
		return;
	end

	if (wnd.space.selected == wnd) then
		wnd.space.selected = nil;
	end

	if (wnd.space.previous == wnd) then
		wnd.space.previous = nil;
	end

-- drop selection references unless we can find a new one,
-- or move to child if there is one
	if (wnd.wm.selected == wnd) then
		wnd:prev();
		if (wnd.wm.selected == wnd) then
			if (wnd.children[1] ~= nil) then
				wnd.children[1]:select();
			else
				wnd.wm.selected = nil;
			end
		end
	end

-- create if it doesn't exist
	if (newspace == nil) then
		wnd.wm.spaces[ind] = create_workspace(wnd.wm);
		newspace = wnd.wm.spaces[ind];
	end

	local seltgt = wnd.wm.selected;

-- reparent
	table.remove_match(wnd.parent.children, wnd);
	for i,v in ipairs(wnd.children) do
		table.insert(wnd.parent.children, v);
		v.parent = wnd.parent;
	end

-- update workspace assignment
	wnd.children = {};
	local oldspace = wnd.space;
	wnd.space = newspace;
	wnd.parent = newspace;
	link_image(wnd.anchor, newspace.anchor);
	table.insert(newspace.children, wnd);

-- restore vid structure etc. to the default state
	if (oldspace.reassign_hook and newspace.mode ~= oldspace.mode) then
		oldspace:reassign_hook(wnd);
	end

-- weights aren't useful for new space, reset
	wnd.weight = 1.0;
	wnd.vweight = 1.0;
	wnd:deselect();

-- subtle resize in order to propagate resize events while still hidden
	if (not(newspace.selected and newspace.selected.fullscreen)) then
		newspace.selected = wnd;
		newspace:resize();
		if (not ninv) then
			newspace:deactivate(true);
		end
	end

	oldspace:resize();
	wnd.wm:update_statusbar();
end

local function wnd_move(wnd, dx, dy, align)
	if (wnd.space.mode ~= "float") then
		return;
	end

	if (align) then
		local pos = image_surface_properties(wnd.anchor);
		pos.x = pos.x + dx;
		pos.y = pos.y + dy;
		if (dx ~= 0) then
			pos.x = pos.x + (dx + -1 * dx) * math.fmod(pos.x, math.abs(dx));
		end
		if (dy ~= 0) then
			pos.y = pos.y + (dy + -1 * dy) * math.fmod(pos.y, math.abs(dy));
		end
		pos.x = pos.x < 0 and 0 or pos.x;
		pos.y = pos.y < 0 and 0 or pos.y;

		move_image(wnd.anchor, pos.x, pos.y);
	else
		nudge_image(wnd.anchor, dx, dy);
	end
end

--
-- re-adjust each window weight, they are not allowed to go down to negative
-- range and the last cell will always pad to fit
--
local function wnd_grow(wnd, w, h)
	if (wnd.space.mode == "float") then
		wnd:resize(wnd.width + (wnd.wm.width*w), wnd.height + (wnd.wm.height*h));
		return;
	end

	if (wnd.space.mode ~= "tile") then
		return;
	end

	if (h ~= 0) then
		wnd.vweight = wnd.vweight + h;
		wnd.parent.vweight = wnd.parent.vweight - h;
	end

	if (w ~= 0) then
		wnd.weight = wnd.weight + w;
		if (#wnd.parent.children > 1) then
			local ws = w / (#wnd.parent.children - 1);
		for i=1,#wnd.parent.children do
			if (wnd.parent.children[i] ~= wnd) then
				wnd.parent.children[i].weight = wnd.parent.children[i].weight - ws;
			end
		end
		end
	end

	wnd.space:resize();
end

local function wnd_title(wnd, message)
	local props = image_surface_properties(wnd.titlebar);
	if (valid_vid(wnd.title_temp)) then
		delete_image(wnd.title_temp);
		wnd.title_temp = nil;
	end

	if (type(message) == "string") then
		wnd.title_text = message;
		message = render_text({gconfig_get("tbar_textstr"),
			wnd.title_prefix and (wnd.title_prefix .. ": ") or "",
			"", wnd.title_text}
		);
	end

	if (not valid_vid(message)) then
		if (props.opacity <= 0.001) then
			return;
		end
		hide_image(wnd.titlebar);
		local vch = wnd.pad_top - 1;
		wnd.pad_top = wnd.pad_top - gconfig_get("tbar_sz");
		if (vch > 0 and wnd.space.mode ~= "float") then
			wnd.space:resize();
		end
		return;
	end

	if (props.opacity <= 0.001) then
		show_image(wnd.titlebar);
		wnd.pad_top = wnd.pad_top + gconfig_get("tbar_sz");
		wnd.space:resize();
	end

	link_image(message, wnd.titlebar);
	image_tracetag(message, "wnd_titletext");
	wnd.title_temp = message;
	image_clip_on(message, CLIP_SHALLOW);
	image_mask_set(message, MASK_UNPICKABLE);
	resize_image(wnd.titlebar,
		wnd.width - wnd.border_w * 2, gconfig_get("tbar_sz"));
	image_inherit_order(message, 1);

	local yp = math.floor(0.5 * (gconfig_get("tbar_sz") -
		image_surface_properties(message).height));

	local pad = gconfig_get("tbar_pad");
	move_image(message, pad, pad + yp);
	show_image(message);
end

local function wnd_mouseown(ctx, vid, event)
	local wnd = ctx.wnd;
	return vid == wnd.canvas or vid == wnd.titlebar or vid == wnd.border;
end

local function convert_mouse_xy(wnd, x, y)
-- note, this should really take viewport into account (if provided), when
-- doing so, move this to be part of fsrv-resize and manual resize as this is
-- rather wasteful.
	local res = {};
	local sprop = image_storage_properties(wnd.external);
	local aprop = image_surface_resolve_properties(wnd.canvas);
	local sfx = sprop.width / aprop.width;
	local sfy = sprop.height / aprop.height;
	local lx = sfx * (x - aprop.x);
	local ly = sfy * (y - aprop.y);

	res[1] = lx;
	res[2] = 0;
	res[3] = ly;
	res[4] = 0;

	if (wnd.last_ms) then
		res[2] = (wnd.last_ms[1] - res[1]);
		res[4] = (wnd.last_ms[2] - res[3]);
	else
		wnd.last_ms = {};
	end

	wnd.last_ms[1] = res[1];
	wnd.last_ms[2] = res[3];
	return res;
end

local function wnd_mousebutton(ctx, vid, ind, pressed, x, y)
	local wnd = ctx.wnd;
	if (wnd.wm.selected ~= wnd) then
		return;
	end

	if (not (vid == wnd.canvas and
		valid_vid(wnd.external, TYPE_FRAMESERVER))) then
		return;
	end

	output_mouse_devent({
		active = pressed, devid = 0, subid = ind}, wnd);
end

local function wnd_mouseclick(ctx, vid)
	local wnd = ctx.wnd;

	if (wnd.wm.selected ~= wnd and
		gconfig_get("mouse_focus_event") == "click") then
		ctx.wnd:select();
		return;
	end

	if (not (vid == wnd.canvas and
		valid_vid(wnd.external, TYPE_FRAMESERVER))) then
		return;
	end

	output_mouse_devent({
		active = true, devid = 0, subid = 0, gesture = true, label = "click"}, wnd);
end

local function wnd_mousedblclick(ctx, vid)
-- will get click before dblclick so focus is no problem
	local wnd = ctx.wnd;
	if (wnd.space.mode == "float" and wnd.titlebar == vid) then
		if (wnd.float_dim) then
			move_image(wnd.anchor, wnd.float_dim.x, wnd.float_dim.y);
			wnd:resize(wnd.float_dim.w, wnd.float_dim.h);
			wnd.float_dim = nil;
		else
			local cur = {};
			local props = image_surface_resolve_properties(wnd.anchor);
			cur.x = props.x;
			cur.y = props.y;
			cur.w = wnd.width;
			cur.h = wnd.height;
			wnd.float_dim = cur;
			wnd:resize(wnd.wm.width, wnd.wm.height);
			move_image(wnd.anchor, 0, 0);
		end
	elseif (wnd.canvas == vid and valid_vid(wnd.external, TYPE_FRAMESERVER)) then
		output_mouse_devent({
			active = true, devid = 0, subid = 0, label = "dblclick", gesture = true
		}, wnd);
	end
end

local function wnd_mousepress(ctx, vid)
	local wnd = ctx.wnd;
	if (wnd.wm.selected ~= ctx.wnd) then
		if (gconfig_get("mouse_focus_event") == "click") then
			ctx.wnd:select();
		end
		return;
	end

	if (wnd.space.mode ~= "float") then
		return;
	end

	table.remove_match(wnd.wm.windows, wnd);
	table.insert(wnd.wm.windows, wnd);
	reorder_space(wnd.space);
end

local function wnd_mousemotion(ctx, vid, x, y, relx, rely)
	local wnd = ctx.wnd;

	if (vid == wnd.canvas and valid_vid(wnd.external, TYPE_FRAMESERVER)) then
		local mv = convert_mouse_xy(wnd, x, y);
		local iotbl = {
			kind = "analog",
			source = "mouse",
			devid = 0,
			subid = 0,
			samples = {mv[1], mv[2]}
		};
		local iotbl2 = {
			kind = "analog",
			source = "mouse",
			devid = 0,
			subid = 1,
			samples = {mv[3], mv[4]}
		};

-- with rate limited mouse events (those 2khz gaming mice that likes
-- to saturate things even when not needed), we accumulate relative samples
		if (not wnd.rate_unlimited) then
			local ep = EVENT_SYNCH[wnd.canvas].pending;
			if (ep) then
				ep[1].samples[1] = mv[1];
				ep[1].samples[2] = ep[1].samples[2] + mv[2];
				ep[2].samples[1] = mv[3];
				ep[2].samples[2] = ep[2].samples[2] + mv[4];
			else
				EVENT_SYNCH[wnd.canvas].pending = {iotbl, iotbl2};
			end
		else
			target_input(wnd.external, iotbl);
			target_input(wnd.external, iotbl2);
		end
	end
end

local function dist(x, y)
	return math.sqrt(x * x + y * y);
end

-- returns: [ul, u, ur, r, lr, l, ll, l]
local function wnd_borderpos(wnd)
	local x, y = mouse_xy();
	local props = image_surface_resolve_properties(wnd.anchor);

-- hi-clamp radius, select corner by distance (priority)
	local cd_ul = dist(x-props.x, y-props.y);
	local cd_ur = dist(props.x + props.width - x, y - props.y);
	local cd_ll = dist(x-props.x, props.y + props.height - y);
	local cd_lr = dist(props.x + props.width - x, props.y + props.height - y);

	local lim = 16 < (0.5 * props.width) and 16 or (0.5 * props.width);
	if (cd_ur < lim) then
		return "ur";
	elseif (cd_lr < lim) then
		return "lr";
	elseif (cd_ll < lim) then
		return "ll";
	elseif (cd_ul < lim) then
		return "ul";
	end

	local dle = x-props.x;
	local dre = props.x+props.width-x;
	local due = y-props.y;
	local dde = props.y+props.height-y;

	local dx = dle < dre and dle or dre;
	local dy = due < dde and due or dde;

	if (dx < dy) then
		return dle < dre and "l" or "r";
	else
		return due < dde and "u" or "d";
	end
end

local function wnd_mousedrop(ctx, vid)
	mouse_switch_cursor("default");
end

local function wnd_mousedrag(ctx, vid, dx, dy)
	local wnd = ctx.wnd;

-- special forward for canvas, else no events would be received during
-- press / release cycle
	if (vid == wnd.canvas and valid_vid(wnd.external, TYPE_FRAMESERVER)) then
		local mx, my = mouse_xy();
		return wnd_mousemotion(ctx, vid, mx, my, dx, dy);
	end

	if (wnd.space.mode ~= "float") then
		return;
	end

	if (vid == wnd.titlebar) then
		nudge_image(wnd.anchor, dx, dy);
		order_image(wnd.anchor, #wnd.wm.windows * WND_RESERVED + WND_RESERVED);
		mouse_switch_cursor("drag", 0);

	elseif (vid == wnd.border) then
		dx = dx * ctx.mask[1];
		dy = dy * ctx.mask[2];
		mouse_switch_cursor(ctx.cursor);
		dx = (wnd.width + dx < wnd.wm.min_width) and 0 or dx;
		dy = (wnd.height + dy < wnd.wm.min_height) and 0 or dy;
		wnd:resize(wnd.width + dx, wnd.height + dy);
		nudge_image(wnd.anchor, dx * ctx.mask[3], dy * ctx.mask[4]);
		wnd.float_dim = nil;
	end
end

local dir_lut = {
	ul = {"rz_diag_r", {-1, -1, -1, -1}},
	 u = {"rz_up", {0, -1, 0, -1}},
	ur = {"rz_diag_l", {1, -1, 0, -1}},
	 r = {"rz_right", {1, 0, 0, 0}},
	lr = {"rz_diag_r", {1, 1, 0, 0}},
	 d = {"rz_down", {0, 1, 0, 0}},
	ll = {"rz_diag_l", {-1, 1, -1, 0}},
	 l = {"rz_left", {-1, 0, -1, 0}}
};

local function wnd_mousehover(ctx, vid)
	local wnd = ctx.wnd;
-- this event can be triggered slightly deferred and race against destroy
	if (not wnd.wm) then
		return;
	end

	if (wnd.wm.selected ~= ctx.wnd and
		gconfig_get("mouse_focus_event") == "hover") then
		wnd:select();
	end
-- good place for tooltip hover hint
end

local function wnd_mouseover(ctx, vid)
-- focus follows mouse
	local wnd = ctx.wnd;

	if (wnd.wm.selected ~= ctx.wnd and
		gconfig_get("mouse_focus_event") == "motion") then
		wnd:select();
	end

	if (wnd.space.mode == "float") then
		if (vid == wnd.titlebar) then
			mouse_switch_cursor("grabhint");
		elseif (vid == wnd.border) then
			local p = wnd_borderpos(wnd);
			local ent = dir_lut[p];
			ctx.cursor = ent[1];
			ctx.mask = ent[2];
			mouse_switch_cursor(ctx.cursor);
		end
	end

	if (vid == wnd.canvas) then
		mouse_switch_cursor(wnd.cursor);
		if (wnd.cursor == "hidden") then
			mouse_hide();
		end
	end
end

local function wnd_mouseout(ctx, vid)
	mouse_switch_cursor("default");
	if (ctx.wnd.canvas == vid and ctx.wnd.cursor == "hidden") then
		mouse_show();
	end
end

seqn = 1;
local function add_mousehandler(wnd)
	local mh = {
		own = wnd_mouseown,
		button = wnd_mousebutton,
		press = wnd_mousepress,
		click = wnd_mouseclick,
		dblclick = wnd_mousedblclick,
		hover = wnd_mousehover,
		motion = wnd_mousemotion,
		drag = wnd_mousedrag,
		drop = wnd_mousedrop,
		over = wnd_mouseover,
		out = wnd_mouseout,
		name = "wnd_mouseh" .. tostring(seqn);
	};
	seqn = seqn + 1;
	wnd.mouse_handler = mh;
	mh.wnd = wnd;
	mouse_addlistener(mh, {
		"button", "hover","motion",
		"click", "press","drop", "dblclick",
		"drag","over","out"
	});
end

local function wnd_alert(wnd)
	local wm = wnd.wm;

	if (not wm.selected or wm.selected == wnd) then
		return;
	end

	if (wnd.space ~= wm.spaces[wm.space_ind]) then
		image_shader(wnd.space.label_id, "tile_alert");
	end

	image_sharestorage(wm.alert_color, wnd.titlebar);
	image_sharestorage(wm.alert_color, wnd.border);
end

local function wnd_prefix(wnd, prefix)
	wnd.title_prefix = prefix and prefix or "";
	wnd:set_title(wnd.title_text and wnd.title_text or "");
end

local function wnd_addhandler(wnd, ev, fun)
	assert(ev);
	if (wnd.handlers[ev] == nil) then
		warning("tried to add handler for unknown event: " .. ev);
		return;
	end
	table.remove_match(wnd.handlers[ev], fun);
	table.insert(wnd.handlers[ev], fun);
end

local function wnd_dispmask(wnd, val, noflush)
	wnd.dispmask = val;
	if (not noflush and valid_vid(wnd.external, TYPE_FRAMESERVER)) then
		target_displayhint(wnd.external, 0, 0, wnd.dispmask);
	end
end

local function wnd_migrate(wnd, tiler)
	if (tiler == wnd.wm) then
		return;
	end

-- select next in line
	wnd:prev();
	if (wnd.wm.selected == wnd) then
		if (wnd.children[1] ~= nil) then
			wnd.children[1]:select();
		else
			wnd.wm.selected = nil;
		end
	end

-- reassign children to parent
	for i,v in ipairs(wnd.children) do
		table.insert(wnd.parent.children, v);
	end
	wnd.children = {};
	for i,v in ipairs(get_hier(wnd.anchor)) do
		rendertarget_attach(tiler.rtgt_id, v, RENDERTARGET_DETACH);
	end
	rendertarget_attach(tiler.rtgt_id, wnd.anchor, RENDERTARGET_DETACH);
	local ind = table.find_i(wnd.parent.children, wnd);
	table.remove(wnd.parent.children, ind);

	if (wnd.fullscreen) then
		wnd.space:tile();
	end

-- change association with wm and relayout old one
	local oldsp = wnd.space;
	table.remove_match(wnd.wm.windows, wnd);
	wnd.wm = tiler;

-- employ relayouting hooks to currently active ws
	local dsp = tiler.spaces[tiler.space_ind];
	wnd:assign_ws(dsp, true);
end

local function wnd_loadcfg(wnd)
	if (not wnd.config_tgt) then
		return;
	end

-- check for:
-- shader, scalemode, tag, last known workspace tag,
-- float position, float size, last known state, local
-- clipboard contents:
--
--

	if (type(config_tgt) == "table") then
-- use, opttgt, optarg arguments for keylist
	end

-- grab config_tgt and generate prefix string
-- sweep the known default domans (i.e. labels, position, ...)
end

local function wnd_create(wm, source, opts)
	if (opts == nil) then opts = {}; end

	local bw = gconfig_get("borderw");
	local res = {
		anchor = null_surface(1, 1),
-- we use fill surfaces rather than color surfaces to get texture coordinates
		border = fill_surface(1, 1, 255, 255, 255),
		titlebar = fill_surface(1,
			gconfig_get("tbar_sz"), unpack(gconfig_get("tbar_bg"))),
		canvas = source,
		gain = 1.0,
		children = {},
		relatives = {},
		dispatch = {},
-- matching between the symtable LUTSYMS and abstract
-- labels that an external target may setup / define
		labels = {},
		handlers = {
			destroy = {},
			resize = {},
			gained_relative = {},
			lost_relative = {},
			select = {},
			deselect = {}
		},
		dispmask = 0,
		pad_left = bw,
		pad_right = bw,
		pad_top = bw,
		pad_bottom = bw,

-- scale factor is manipulated by the display manager in order to take pixel
-- density into account, so when a window is migrated or similar -- scale
-- factor may well change
		scale_factor = 1.0,
		width = wm.min_width,
		height = wm.min_height,
		border_w = gconfig_get("borderw"),
		effective_w = 0,
		effective_h = 0,
		weight = 1.0,
		vweight = 1.0,
		scalemode = opts.scalemode and opts.scalemode or "normal",
		load_config = wnd_loadcfg,
		alert = wnd_alert,
		assign_ws = wnd_reassign,
		destroy = wnd_destroy,
		set_message = wnd_message,
		set_title = wnd_title,
		set_prefix = wnd_prefix,
		add_handler = wnd_addhandler,
		set_dispmask = wnd_dispmask,
		update_font = wnd_font,
		resize = wnd_resize,
		migrate = wnd_migrate,
		resize_effective = wnd_effective_resize,
		select = wnd_select,
		deselect = wnd_deselect,
		next = wnd_next,
		merge = wnd_merge,
		collapse = wnd_collapse,
		prev = wnd_prev,
		move =wnd_move,
		grow = wnd_grow,
		name = "wnd_" .. tostring(ent_count),
-- user defined, for storing / restoring
		settings = {},
-- Explicit whitelist of allowed segment kinds (clipboard handled separately)
-- expected to be indexed by segkind (string) and map to a table that has one
-- function (register(srctbl)). This must call accept_target and will only be
-- invoked from the context of a segment_request
		allowed_subseg = {}
	};

	if (wm.debug_console) then
		wm.debug_console:system_event(string.format("new window using %d", source));
	end

	ent_count = ent_count + 1;
	image_tracetag(res.anchor, "wnd_anchor");
	image_tracetag(res.border, "wnd_border");
	image_tracetag(res.canvas, "wnd_canvas");
	image_tracetag(res.titlebar, "wnd_titlebar");
	res.wm = wm;

	image_mask_set(res.anchor, MASK_UNPICKABLE);

-- initially, titlebar stays hidden
	link_image(res.titlebar, res.anchor);
	image_inherit_order(res.titlebar, true);
	move_image(res.titlebar, bw, bw);
	if (wm.spaces[wm.space_ind] == nil) then
		wm.spaces[wm.space_ind] = create_workspace(wm);
		wm:update_statusbar();
	end

	local space = wm.spaces[wm.space_ind];
	image_inherit_order(res.anchor, true);
	image_inherit_order(res.border, true);
	image_inherit_order(res.canvas, true);

	link_image(res.canvas, res.anchor);
	link_image(res.border, res.anchor);

	order_image(res.titlebar, 2);
	order_image(res.canvas, 2);

	image_shader(res.border, "border_inact");
	show_image({res.border, res.canvas});

	if (not wm.selected or wm.selected.space ~= space) then
		table.insert(space.children, res);
		res.parent = space;

	elseif (space.insert == "horizontal") then
		if (wm.selected.parent) then
			table.insert(wm.selected.parent.children, res);
			res.parent = wm.selected.parent;
		else
			table.insert(space.children, res);
			res.parent = space;
		end
	else
		table.insert(wm.selected.children, res);
		res.parent = wm.selected;
	end

	res.space = space;
	link_image(res.anchor, space.anchor);
	table.insert(wm.windows, res);
	order_image(res.anchor, #wm.windows * WND_RESERVED);
	if (not(wm.selected and wm.selected.fullscreen)) then
		show_image(res.anchor);
		space:resize(res);
		res:select();
	else
		image_shader(res.border, "border_inact");
		image_sharestorage(res.wm.border_color, res.border);
	end

	if (not opts.block_mouse) then
		add_mousehandler(res);
	end

	if (res.space.mode == "float") then
		move_image(res.anchor, mouse_xy());
		res:resize(wm.min_width, wm.min_height);
	end

	order_image(res.wm.order_anchor,
		2 + #wm.windows * WND_RESERVED + 2 * WND_RESERVED);

	return res;
end

local function tick_windows(wm)
	for k,v in ipairs(wm.windows) do
		if (v.tick) then
			v:tick();
		end
	end
end

local function tiler_find(wm, source)
	for i=1,#wm.windows do
		if (wm.windows[i].canvas == source) then
			return wm.windows[i];
		end
	end
	return nil;
end

local function tiler_switchws(wm, ind)
	if (type(ind) ~= "number") then
		for k,v in pairs(wm.spaces) do
			if (type(ind) == "table" and v == ind) then
				ind = k;
				break;
			elseif (type(ind) == "string" and v.label == ind) then
				ind = k;
				break;
			end
		end
-- no match
		if (type(ind) ~= "number") then
			return;
		end
	end

	local cw = wm.selected;
	if (ind == wm.space_ind) then
		return;
	end

	local nd = wm.space_ind < ind;
	local cursp = wm.spaces[wm.space_ind];
	local nextsp = wm.spaces[ind];

	if (cursp.switch_hook) then
		cursp:switch_hook(false, nd);
	else
		workspace_deactivate(cursp, false, nd, nextsp and nextsp.background or nil);
	end

-- policy, don't autodelete if the user has made some kind of customization
	if (#cursp.children == 0 and gconfig_get("ws_autodestroy") and
		(cursp.label == nil or string.len(cursp.label) == 0 ) and
		cursp.background_name == nil) then
		cursp:destroy();
		wm.spaces[wm.space_ind] = nil;
	else
		cursp.selected = cw;
	end

	if (wm.spaces[ind] == nil) then
		wm.spaces[ind] = create_workspace(wm);
	end

	wm.space_ind = ind;
	tile_upd(wm);

	if (wm.spaces[ind].switch_hook) then
		wm.spaces[ind]:switch_hook(true, not nd);
	else
		workspace_activate(wm.spaces[ind], false, not nd, cursp.background);
	end

-- safeguard against broken state
	wm.spaces[ind].selected = wm.spaces[ind].selected and
		wm.spaces[ind].selected or wm.spaces[ind].children[1];

	if (wm.spaces[ind].selected) then
		wnd_select(wm.spaces[ind].selected);
	else
		wm.selected = nil;
	end
end

local function tiler_swapws(wm, ind2)
	local ind1 = wm.space_ind;

	if (ind2 == ind1) then
		return;
	end
  tiler_switchws(wm, ind2);
-- now space_ind is ind2 and ind2 is visible and hooks have been run
	local space = wm.spaces[ind2];
	wm.spaces[ind2] = wm.spaces[ind1];
 	wm.spaces[ind1] = space;
	wm.space_ind = ind1;
 -- now the swap is done with, need to update bar again
	if (valid_vid(wm.spaces[ind1].label_id)) then
		mouse_droplistener(wm.spaces[ind1].tile_ml);
		delete_image(wm.spaces[ind1].label_id);
		wm.spaces[ind1].label_id = nil;
	end

	if (valid_vid(wm.spaces[ind2].label_id)) then
		mouse_droplistener(wm.spaces[ind1].tile_m2);
		delete_image(wm.spaces[ind2].label_id);
		wm.spaces[ind2].label_id = nil;
	end

	tile_upd(wm);
end

local function wnd_swap(w1, w2, deep)
	if (w1 == w2) then
		return;
	end
-- 1. weights, only makes sense in tile mode
	if (w1.space.mode == "tile") then
		local wg1 = w1.weight;
		local wg1v = w1.vweight;
		w1.weight = w2.weight;
		w1.vweight = w2.vweight;
		w2.weight = wg1;
		w2.vweight = wg1v;
	end
-- 2. parent->children entries
	local wp1 = w1.parent;
	local wp1i = table.find_i(wp1.children, w1);
	local wp2 = w2.parent;
	local wp2i = table.find_i(wp2.children, w2);
	wp1.children[wp1i] = w2;
	wp2.children[wp2i] = w1;
-- 3. parents
	w1.parent = wp2;
	w2.parent = wp1;
-- 4. question is if we want children to tag along or not
	if (not deep) then
		for i=1,#w1.children do
			w1.children[i].parent = w2;
		end
		for i=1,#w2.children do
			w2.children[i].parent = w1;
		end
		local wc = w1.children;
		w1.children = w2.children;
		w2.children = wc;
	end
end

local function tiler_swapup(wm, deep, resel)
	local wnd = wm.selected;
	if (not wnd or wnd.parent.parent == nil) then
		return;
	end

	local p1 = wnd.parent;
	wnd_swap(wnd, wnd.parent, deep);
	if (resel) then
		p1:select();
	end

	wnd.space:resize();
end

local function tiler_swapdown(wm, resel)
	local wnd = wm.selected;
	if (not wnd or #wnd.children == 0) then
		return;
	end

	local pl = wnd.children[1];
	wnd_swap(wnd, wnd.children[1]);
	if (resel) then
		pl:select();
	end

	wnd.space:resize();
end

local function tiler_swapleft(wm, deep, resel)
	local wnd = wm.selected;
	if (not wnd) then
		return;
	end

	local ind = table.find_i(wnd.parent.children, wnd);
	assert(ind);

	if ((ind ~= 1 or wnd.parent.parent == nil) and #wnd.parent.children > 1) then
		local li = (ind - 1) == 0 and #wnd.parent.children or (ind - 1);
		local oldi = wnd.parent.children[li];
		wnd_swap(wnd, oldi, deep);
		if (resel) then oldi:select(); end
	elseif (ind == 1 and wnd.parent.parent) then
		local root_node = wnd.parent;
		while (root_node.parent.parent) do
			root_node = root_node.parent;
		end
		local li = table.find_i(root_node.parent.children, root_node);
		li = (li - 1) == 0 and #root_node.parent.children or (li - 1);
		wnd_swap(wnd, root_node.parent.children[li]);
	end
	wnd.space:resize();
end

local function tiler_swapright(wm, deep, resel)
	local wnd = wm.selected;
	if (not wnd) then
		return;
	end

	local ind = table.find_i(wnd.parent.children, wnd);
	assert(ind);

	if ((ind ~= 1 or wnd.parent.parent == nil) and #wnd.parent.children > 1) then
		local li = (ind + 1) > #wnd.parent.children and 1 or (ind + 1);
		local oldi = wnd.parent.children[li];
		wnd_swap(wnd, oldi, deep);
		if (resel) then oldi:select(); end
	elseif (ind == 1 and wnd.parent.parent) then
		local root_node = wnd.parent;
		while (root_node.parent.parent) do
			root_node = root_node.parent;
		end
		local li = table.find_i(root_node.parent.children, root_node);
		li = (li + 1) > #root_node.parent.children and 1 or (li + 1);
		wnd_swap(wnd, root_node.parent.children[li]);
	end

	wnd.space:resize();
end

local function tiler_message(tiler, msg, timeout)
	local msgvid;
	if (timeout ~= -1) then
		timeout = gconfig_get("msg_timeout");
	end

	if (not msg) then
		if (valid_vid(tiler.statusbar_msg)) then
			delete_image(tiler.statusbar_msg);
			tiler.statusbar_msg = nil;
		end
	else
		tiler_statusbar_update(tiler, nil, msg, timeout);
	end
end

local function tiler_rebuild_border(tiler)
	local bw = gconfig_get("borderw");
	build_shaders();
	if (tiler == nil) then
		print(debug.traceback());
	end
	for i,v in ipairs(tiler.windows) do
		local old_bw = v.border_w;
		v.pad_left = v.pad_left - old_bw + bw;
		v.pad_right = v.pad_right - old_bw + bw;
		v.pad_top = v.pad_top - old_bw + bw;
		v.pad_bottom = v.pad_bottom - old_bw + bw;
		v.border_w = bw;
		if (v.space.mode == "tile" or v.space.mode == "float") then
			move_image(v.titlebar, v.border_w, v.border_w);
			resize_image(v.titlebar,
			v.width - v.border_w * 2, gconfig_get("tbar_sz"));
		end
	end
end

local function tiler_rendertarget(wm, set)
	if (set == nil or (wm.rtgt_id and set) or (not set and not wm.rtgt_id)) then
		return wm.rtgt_id;
	end

	local list = get_hier(wm.anchor);

-- the surface we use as rendertarget for compositioning will use the highest
-- quality internal storage format, and disable the use of the alpha channel
	if (set == true) then
		wm.rtgt_id = alloc_surface(wm.width, wm.height, true, 1);
		image_tracetag(wm.rtgt_id, "tiler_rt");
		local pitem = null_surface(32, 32); --workaround for rtgt restriction
		image_tracetag(pitem, "rendertarget_placeholder");
		define_rendertarget(wm.rtgt_id, {pitem});
		for i,v in ipairs(list) do
			rendertarget_attach(wm.rtgt_id, v, RENDERTARGET_DETACH);
		end
	else
		for i,v in ipairs(list) do
			rendertarget_attach(WORLDID, v, RENDERTARGET_DETACH);
		end
		delete_image(rt);
		wm.rtgt_id = nil;
	end
	image_texfilter(wm.rtgt_id, FILTER_NONE);
	return wm.rtgt_id;
end

local function wm_countspaces(wm)
	local r = 0;
	for i=1,10 do
		r = r + (wm.spaces[i] ~= nil and 1 or 0);
	end
	return r;
end

local function tiler_input_lock(wm, dst)
	if (wm.debug_console) then
		wm.debug_console:system_event(dst and ("input lock set to "
			.. tostring(dst)) or "input lock cleared");
	end
	wm.input_lock = dst;
end

local function tiler_resize(tiler, neww, newh)
	tiler.width = neww;
	tiler.height = newh;
	if (valid_vid(tiler.rtgt_id)) then
		image_resize_storage(tiler.rtgt_id, neww, newh);
	end
	for k,v in pairs(tiler.spaces) do
		v:resize(neww, newh);
	end
	tile_upd(tiler);
end

function tiler_create(width, height, opts)
	opts = opts == nil and {} or opts;

	local res = {
-- null surfaces for clipping / moving / drawing
		name = opts.name and opts.name or "default",
		anchor = null_surface(1, 1),
		order_anchor = null_surface(1, 1),
		statusbar = color_surface(width, gconfig_get("sbar_sz"),
			unpack(gconfig_get("sbar_bg"))),
		empty_space = workspace_empty,

-- pre-alloc these as they will be re-used a lot
		border_color = fill_surface(1, 1,
			unpack(gconfig_get("tcol_inactive_border"))),

		alert_color = fill_surface(1, 1,
			unpack(gconfig_get("tcol_alert"))),

		active_tbar_color = fill_surface(1, 1,
			unpack(gconfig_get("tbar_active"))),

		tbar_color = fill_surface(1, 1,
			unpack(gconfig_get("tbar_inactive"))),

		active_border_color = fill_surface(1, 1,
			unpack(gconfig_get("tcol_border"))),

		lbar = tiler_lbar,
		tick = tick_windows,

-- management members
		spaces = {},
		windows = {},
		space_ind = 1,

-- debug

-- kept per/tiler in order to allow custom modes as well
		scalemodes = {"normal", "stretch", "aspect"},

-- public functions
		switch_ws = tiler_switchws,
		swap_ws = tiler_swapws,
		swap_up = tiler_swapup,
		swap_down = tiler_swapdown,
		swap_left = tiler_swapleft,
		swap_right = tiler_swapright,
		active_spaces = wm_countspaces,
		set_rendertarget = tiler_rendertarget,
		add_window = wnd_create,
		find_window = tiler_find,
		message = tiler_message,
		resize = tiler_resize,
		tile_update = tile_upd,
		invalidate_statusbar = tiler_statusbar_invalidate,
		update_statusbar = tiler_statusbar_update,
		rebuild_border = tiler_rebuild_border,
		set_input_lock = tiler_input_lock
	};
	res.width = width;
	res.height = height;
	res.min_width = 32;
	res.min_height = 32;

	image_tracetag(res.anchor, "tiler_anchor");
	image_tracetag(res.order_anchor, "tiler_order_anchor");
	image_tracetag(res.statusbar, "tiler_statusbar");

	order_image(res.order_anchor, 2);
	move_image(res.statusbar, 0, clh);
	link_image(res.statusbar, res.order_anchor);
	image_inherit_order(res.statusbar, true);
	order_image(res.statusbar, 1);
	image_mask_set(res.statusbar, MASK_UNPICKABLE);
	show_image({res.anchor, res.statusbar, res.order_anchor});
	link_image(res.order_anchor, res.anchor);

-- unpack preset workspaces from saved keys
	local mask = string.format("wsk_%s_%%", res.name);
	local wstbl = {};
	for i,v in ipairs(match_keys(mask)) do
		local pos, stop = string.find(v, "=", 1);
		local key = string.sub(v, 1, pos-1);
		local ind, cmd = string.match(key, "(%d+)_(%a+)$");
		if (ind ~= nil and cmd ~= nil) then
			ind = tonumber(ind);
			if (wstbl[ind] == nil) then wstbl[ind] = {}; end
			local val = string.sub(v, pos+1);
			wstbl[ind][cmd] = val;
		end
	end

	for k,v in pairs(wstbl) do
		res.spaces[k] = create_workspace(res, true);
		for ind, val in pairs(v) do
			if (ind == "mode") then
				res.spaces[k].mode = val;
			elseif (ind == "insert") then
				res.spaces[k].insert = val;
			elseif (ind == "bg") then
				res.spaces[k]:set_background(val);
			elseif (ind == "label") then
				res.spaces[k]:set_label(val);
			end
		end
	end

	local v = get_key(string.format("ws_%s_bg", res.name));
	if (v) then
		res.background_name = load_image(v);
	end

-- always make sure we have a 'first one'
	if (not res.spaces[1]) then
		res.spaces[1] = create_workspace(res, true);
	end
	tile_upd(res);

	return res;
end
