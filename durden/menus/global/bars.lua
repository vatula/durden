local function remove_button(dir)
	local res = {};

	for group, list in pairs(gconfig_buttons) do
		for i,v in ipairs(list) do
			if (not dir or v.direction == string.lower(dir)) then
				table.insert(res, {
					name = tostring(i),
					label = group .. "_" .. tostring(i),
					description = "Button Label: " .. v.label,
					kind = "action",
					handler = function()
						table.remove(gconfig_buttons[group], i);
						gconfig_buttons_rebuild();
					end
				});
			end
		end

	end
	return res;
end

local function button_query_path(wnd, vsym, dir, group)
	dispatch_symbol_bind(function(path)
		local wm = active_display();
-- can actually change during interaction time so verify
		table.insert(gconfig_buttons[group], {
			label = vsym,
			direction = dir,
			command = path
		});
		gconfig_buttons_rebuild();
	end);
end

local function titlebar_buttons(dir, lbl)
	local wnd = active_display().selected;
	local hintstr = "(0x:byte seq | icon:ref | string)";
	return
	{
		{
		label = "Remove",
		name = "remove",
		kind = "action",
		submenu = true,
		description = "Remove a button",
		eval = function() return #remove_button(dir) > 0; end,
		handler = function()
			return remove_button(dir);
		end
		},
		{
		label = "Add",
		name = "add",
		kind = "value",
		hint = hintstr,
		validator = function(val)
			return suppl_valid_vsymbol(val);
		end,
		description = "Add a new button used in all layout modes",
		handler = function(ctx, val)
			button_query_path(active_display().selected, val, dir, "all");
		end
		},
		{
		label = "Add (Tile)",
		name = "add_tile",
		kind = "value",
		hint = hintstr,
		description = "Add a new button for tiled layout modes",
		validator = function(val)
			return suppl_valid_vsymbol(val);
		end,
		handler = function(ctx, val)
			local wnd = active_display().selected;
			button_query_path(active_display().selected, val, dir, "tile");
		end
		},
		{
		label = "Add (Float)",
		name = "add_float",
		kind = "value",
		hint = hintstr,
		validator = function(val)
			return suppl_valid_vsymbol(val);
		end,
		description = "Add a new button for floating layout mode",
		handler = function(ctx, val)
			button_query_path(active_display().selected, val, dir, "float");
		end
		}
	}
end

local titlebar_buttons = {
	{
		name = "left",
		kind = "action",
		label = "Left",
		description = "Modify buttons in the left group",
		submenu = true,
		handler = function()
			return titlebar_buttons("left", "Left");
		end
	},
	{
		name = "right",
		kind = "action",
		submenu = true,
		label = "Right",
		description = "Modify buttons in the right group",
		submenu = true,
		handler = function()
			return titlebar_buttons("right", "Right");
		end
	}
};

return
{
	{
		name = "pad_top",
		label = "Pad Top",
		kind = "value",
		description = "Insert extra vertical spacing above the bar text",
		initial = function() return gconfig_get("sbar_tpad"); end,
		validator = function() return gen_valid_num(0, gconfig_get("sbar_sz")); end,
		handler = function(ctx, val)
			gconfig_set("sbar_tpad", tonumber(val));
			gconfig_set("tbar_tpad", tonumber(val));
			gconfig_set("lbar_tpad", tonumber(val));
		end
	},
	{
		name = "pad_bottom",
		label = "Pad Bottom",
		kind = "value",
		description = "Insert extra vertical spacing below the bar- text",
		initial = function() return gconfig_get("sbar_bpad"); end,
		validator = function() return gen_valid_num(0, gconfig_get("sbar_sz")); end,
		handler = function(ctx, val)
			gconfig_set("sbar_bpad", tonumber(val));
			gconfig_set("tbar_bpad", tonumber(val));
			gconfig_set("lbar_bpad", tonumber(val));
		end
	}
};
