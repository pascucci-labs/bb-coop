"use strict";
// BB Co-op UI side: WebSocket, turn banner, toasts and owner badges.
// Squirrel side: scripts/mods/bb_coop/coop_connection.nut
// Written in ES5: Coherent GT runs an old WebKit.

var BBCoopConnection = function ()
{
	MSUBackendConnection.call(this);
	this.mSocket = null;
	this.mRoot = null;
	this.mBanner = null;
	this.mStatus = null;
	this.mToasts = null;
	this.mLastStatus = null;
};

BBCoopConnection.prototype = Object.create(MSUBackendConnection.prototype);
Object.defineProperty(BBCoopConnection.prototype, 'constructor', {
	value: BBCoopConnection,
	enumerable: false,
	writable: true
});

BBCoopConnection.prototype.onConnection = function (_handle)
{
	var self = this;
	MSUBackendConnection.prototype.onConnection.call(this, _handle);
	this.createDIV();
	SQ.call(this.mSQHandle, "onQueryStatus", null, function (_status) { self.setNetStatus(_status); });
};

// The overlay: status light, turn banner, toasts, and the panel/menu when open.
// Rebuilt if a screen change dropped it from the page.
BBCoopConnection.prototype.createDIV = function ()
{
	if (this.mRoot !== null && $.contains(document.body, this.mRoot[0]))
		return;
	this.mRoot = $('<div class="bbcoop-root"/>').appendTo($('body'));
	this.mBanner = $('<div class="bbcoop-banner title-font-big font-bold"/>').appendTo(this.mRoot).hide();
	this.mStatus = $('<div class="bbcoop-light text-font-normal font-bold"/>').appendTo(this.mRoot);
	this.mStatus.append('<span class="bbcoop-light-dot"/>').append('<span class="bbcoop-light-text"/>');
	this.makeLightDraggable();
	this.mToasts = $('<div class="bbcoop-toasts"/>').appendTo(this.mRoot);
	if (this.mLastStatus)
		this.setNetStatus(this.mLastStatus);
};

BBCoopConnection.prototype.notify = function (_type, _data)
{
	if (this.mSQHandle === null)
		return;
	SQ.call(this.mSQHandle, "onNetEvent", { type: _type, data: _data === undefined ? null : _data });
};

// ---- Network -----------------------------------------------------------------

BBCoopConnection.prototype.netConnect = function (_data)
{
	var self = this;
	if (this.mSocket !== null)
		this.netDisconnect();

	var socket;
	try
	{
		socket = new WebSocket(_data.url);
	}
	catch (e)
	{
		this.notify("error", { message: "Could not open WebSocket: " + e });
		this.notify("close", { code: 0, reason: "" });
		return;
	}
	this.mSocket = socket;

	socket.onopen = function ()
	{
		self.notify("open");
		socket.send(JSON.stringify(_data.hello));
	};
	socket.onmessage = function (_event)
	{
		var msg;
		try
		{
			msg = JSON.parse(_event.data);
		}
		catch (e)
		{
			console.error("BBCoop: bad message " + _event.data);
			return;
		}
		self.notify("message", msg);
	};
	socket.onerror = function ()
	{
		self.notify("error", { message: "connection failed (" + _data.url + ")" });
	};
	socket.onclose = function (_event)
	{
		if (self.mSocket === socket)
			self.mSocket = null;
		self.notify("close", { code: _event.code, reason: _event.reason });
	};
};

BBCoopConnection.prototype.netDisconnect = function ()
{
	if (this.mSocket !== null)
	{
		this.mSocket.close();
		this.mSocket = null;
	}
};

BBCoopConnection.prototype.netSend = function (_msg)
{
	if (this.mSocket === null || this.mSocket.readyState !== 1)
		return;
	this.mSocket.send(JSON.stringify(_msg));
};

// Loopback test: send a message back to Squirrel as if it came from the network,
// passing through JSON like a real one.
BBCoopConnection.prototype.loopback = function (_msg)
{
	var self = this;
	var text = JSON.stringify(_msg);
	setTimeout(function () { self.notify("message", JSON.parse(text)); }, 0);
};

// ---- Overlay -----------------------------------------------------------------

BBCoopConnection.prototype.showBanner = function (_data)
{
	this.createDIV();
	this.mBanner.text(_data.text)
		.removeClass('is-p1 is-p2 is-waiting')
		.addClass('is-' + _data.kind)
		.css('background-color', _data.color ? BBCoop.withAlpha(_data.color, 0.85) : '')
		.show();
	if (_data.alert)
	{
		var banner = this.mBanner;
		banner.removeClass('is-alert');
		void banner[0].offsetWidth; // restart the animation
		banner.addClass('is-alert');
		setTimeout(function () { banner.removeClass('is-alert'); }, 2000);
	}
};

BBCoopConnection.prototype.hideBanner = function ()
{
	if (this.mBanner !== null)
		this.mBanner.hide();
};

// Click the light to open the panel; drag it to move it. The spot is remembered.
BBCoopConnection.prototype.makeLightDraggable = function ()
{
	var light = this.mStatus;
	var saved = null;
	try
	{
		saved = JSON.parse(window.localStorage.getItem('bbcoop.lightPos'));
	}
	catch (e)
	{
		saved = null;
	}
	if (saved && typeof saved.left === 'number' && typeof saved.top === 'number')
		light.css({ left: saved.left + 'px', top: saved.top + 'px', right: 'auto' });

	light.on('mousedown', function (_event)
	{
		_event.stopPropagation();
		_event.preventDefault();
		var start = { x: _event.pageX, y: _event.pageY };
		var origin = light.offset();
		var dragged = false;

		var move = function (_e)
		{
			var dx = _e.pageX - start.x;
			var dy = _e.pageY - start.y;
			if (!dragged && Math.abs(dx) + Math.abs(dy) < 5)
				return;
			dragged = true;
			var left = Math.max(0, Math.min($(window).width() - light.outerWidth(), origin.left + dx));
			var top = Math.max(0, Math.min($(window).height() - light.outerHeight(), origin.top + dy));
			light.css({ left: left + 'px', top: top + 'px', right: 'auto' });
		};
		var up = function ()
		{
			$(document).off('mousemove', move).off('mouseup', up);
			if (!dragged)
			{
				BBCoop.togglePanel();
				return;
			}
			try
			{
				window.localStorage.setItem('bbcoop.lightPos', JSON.stringify({ left: light.offset().left, top: light.offset().top }));
			}
			catch (e) { }
		};
		$(document).on('mousemove', move).on('mouseup', up);
	});
	light.on('click', function (_event) { _event.stopPropagation(); });
};

// _status: { state: off|local|offline|connecting|waiting|linked, text, detail }
BBCoopConnection.prototype.setNetStatus = function (_status)
{
	if (_status === null || _status === undefined || typeof _status !== 'object')
		return;
	this.mLastStatus = _status;
	this.createDIV();
	this.mStatus.removeClass('is-off is-local is-offline is-connecting is-waiting is-linked')
		.addClass('is-' + _status.state)
		.attr('title', _status.detail || '');
	this.mStatus.find('.bbcoop-light-text').text(_status.short || _status.text);
	BBCoop.refreshPanel();
	BBCoop.refreshLobby();
};

BBCoopConnection.prototype.showToast = function (_text)
{
	this.createDIV();
	var toast = $('<div class="bbcoop-toast text-font-normal"/>').text(_text).appendTo(this.mToasts);
	setTimeout(function ()
	{
		toast.fadeOut(400, function () { toast.remove(); });
	}, 5000);
};

registerScreen("BBCoopConnection", new BBCoopConnection());

// ---- Owner badges on the character screen's brother list -----------------------

var BBCoop = {
	// "rgb(r,g,b)" -> "rgba(r,g,b,a)"
	withAlpha: function (_rgb, _alpha)
	{
		return _rgb.replace('rgb(', 'rgba(').replace(')', ',' + _alpha + ')');
	},

	// Grey out a portrait when this PC's player doesn't control that brother.
	markOwnership: function (_el, _data)
	{
		var mine = !('bbcoop' in _data) || _data.bbcoop.mine !== false;
		_el.toggleClass('bbcoop-not-mine', !mine);
	},

	addBadge: function (_slot, _data)
	{
		if (_slot === null || _slot.length === 0)
			return;
		_slot.find('.bbcoop-badge').remove();
		BBCoop.markOwnership(_slot, _data);
		if (!('bbcoop' in _data))
			return;

		var info = _data.bbcoop;
		var badge = $('<div class="bbcoop-badge text-font-small"/>')
			.addClass('is-p' + info.owner)
			.css('background-color', info.color)
			.text(info.tag)
			.attr('title', info.name)
			.appendTo(_slot);

		badge.addClass('is-editable');
		badge.on('mousedown', function (_event)
		{
			_event.stopPropagation(); // don't start a drag or select the brother
		});
		badge.on('click', function (_event)
		{
			_event.stopPropagation();
			BBCoop.openMenu(_data[CharacterScreenIdentifier.Entity.Id]);
		});
	},

	// Every call returns { error, menu }. Show the menu if there is one, otherwise the error.
	call: function (_method, _arg)
	{
		var connection = Screens.BBCoopConnection;
		if (connection.mSQHandle === null)
		{
			connection.showToast("Co-op: the UI lost its link to the game scripts. Restart the game.");
			return;
		}
		SQ.call(connection.mSQHandle, _method, _arg, function (_ret)
		{
			if (_ret === null || _ret === undefined)
			{
				connection.showToast("Co-op: " + _method + " returned nothing");
				return;
			}
			if (_ret.menu !== null && _ret.menu !== undefined)
				BBCoop.renderMenu(_ret.menu, _ret.error);
			else if (_ret.error)
				connection.showToast(_ret.error);
		});
	},

	openMenu: function (_entityID)
	{
		BBCoop.call("onQueryCoopMenu", _entityID);
	},

	closeMenu: function ()
	{
		$('.bbcoop-menu').remove();
	},

	retrain: function (_menu, _args)
	{
		_args.id = _menu.id;
		BBCoop.call("onRetrain", _args);
	},

	renderMenu: function (_menu, _error)
	{
		BBCoop.closeMenu();
		BBCoop.closePanel();
		var connection = Screens.BBCoopConnection;
		connection.createDIV();
		var root = connection.mRoot;
		var menu = $('<div class="bbcoop-menu text-font-normal"/>').appendTo(root);
		menu.on('mousedown click', function (_event) { _event.stopPropagation(); });

		$('<div class="bbcoop-menu-title title-font-big font-bold"/>').text(_menu.name).appendTo(menu);
		$('<div class="bbcoop-menu-close">×</div>').appendTo(menu).on('click', BBCoop.closeMenu);

		var owner = $('<div class="bbcoop-menu-row"/>').appendTo(menu);
		owner.append($('<span/>').text('Follows: ' + _menu.badge.name + ' '));
		if (_menu.badge.canEdit)
		{
			BBCoop.button(owner, 'Give to the other player', false, function ()
			{
				BBCoop.call("onToggleOwner", _menu.id);
			});
		}

		$('<div class="bbcoop-menu-heading font-bold"/>').text('Retrain (' + _menu.cost + ' crowns each, treasury: ' + _menu.money + ')').appendTo(menu);

		if (_error !== null && _error !== undefined)
			$('<div class="bbcoop-menu-error"/>').text(_error).appendTo(menu);
		var blocked = _menu.blocked !== null && _menu.blocked !== undefined;
		if (blocked)
			$('<div class="bbcoop-menu-note"/>').text(_menu.blocked).appendTo(menu);

		var row = $('<div class="bbcoop-menu-row"/>').appendTo(menu);
		BBCoop.button(row, 'Reroll attributes', blocked || !_menu.canRerollAttributes, function () { BBCoop.retrain(_menu, { op: 'attributes' }); });
		BBCoop.button(row, 'Reroll talents', blocked, function () { BBCoop.retrain(_menu, { op: 'talents' }); });
		BBCoop.button(row, 'Reset perks', blocked || !_menu.hasSpentPerks, function () { BBCoop.retrain(_menu, { op: 'perks' }); });
		if (!_menu.canRerollAttributes)
			$('<div class="bbcoop-menu-note"/>').text('Attributes can only be rerolled for brothers who joined (or were still level 1) while this mod was installed.').appendTo(menu);

		// Trait swap: pick one to remove and/or one to add.
		var pick = { remove: null, add: null };
		$('<div class="bbcoop-menu-heading font-bold"/>').text('Swap a trait').appendTo(menu);
		var current = $('<div class="bbcoop-trait-list"/>').appendTo(menu);
		if (_menu.traits.length === 0)
			current.append($('<span class="bbcoop-menu-note"/>').text('No traits.'));
		$.each(_menu.traits, function (_, _t)
		{
			BBCoop.trait(current, _t, function (_el)
			{
				current.find('.is-picked').not(_el).removeClass('is-picked');
				_el.toggleClass('is-picked');
				pick.remove = _el.hasClass('is-picked') ? _t.id : null;
			});
		});
		$('<div class="bbcoop-menu-note"/>').text('Click a trait above to remove it, and/or one below to add it.').appendTo(menu);
		var all = $('<div class="bbcoop-trait-list is-all"/>').appendTo(menu);
		$.each(_menu.allTraits, function (_, _t)
		{
			BBCoop.trait(all, _t, function (_el)
			{
				all.find('.is-picked').not(_el).removeClass('is-picked');
				_el.toggleClass('is-picked');
				pick.add = _el.hasClass('is-picked') ? _t.id : null;
			});
		});
		BBCoop.button($('<div class="bbcoop-menu-row"/>').appendTo(menu), 'Swap trait', blocked, function ()
		{
			BBCoop.retrain(_menu, { op: 'trait', remove: pick.remove, add: pick.add });
		});
	},

	button: function (_parent, _text, _disabled, _onClick)
	{
		var b = $('<div class="bbcoop-button"/>').text(_text).appendTo(_parent);
		if (_disabled)
			b.addClass('is-disabled');
		else
			b.on('click', _onClick);
		return b;
	},

	// ---- Co-op panel ------------------------------------------------------------

	mPanelAdvanced: false,

	isPanelOpen: function ()
	{
		return $('.bbcoop-panel').length > 0;
	},

	togglePanel: function ()
	{
		if (BBCoop.isPanelOpen())
			BBCoop.closePanel();
		else
			BBCoop.panelCall("onQueryPanel", null);
	},

	closePanel: function ()
	{
		$('.bbcoop-panel').remove();
	},

	refreshPanel: function ()
	{
		// Don't redraw while the player is typing in one of its boxes.
		if (BBCoop.isPanelOpen() && $('.bbcoop-panel input:focus').length === 0)
			BBCoop.panelCall("onQueryPanel", null);
	},

	panelAction: function (_args)
	{
		BBCoop.panelCall("onPanelAction", _args);
	},

	panelCall: function (_method, _arg)
	{
		var connection = Screens.BBCoopConnection;
		if (connection.mSQHandle === null)
		{
			connection.showToast("Co-op: the UI lost its link to the game scripts. Restart the game.");
			return;
		}
		SQ.call(connection.mSQHandle, _method, _arg, function (_ret)
		{
			if (_ret === null || _ret === undefined || !_ret.panel)
			{
				connection.showToast(_ret && _ret.error ? _ret.error : "Co-op: " + _method + " failed");
				return;
			}
			BBCoop.renderPanel(_ret.panel, _ret.error);
		});
	},

	// A text box that saves when you leave it or press Enter.
	input: function (_parent, _value, _options, _onCommit)
	{
		var el = $('<input type="text" class="bbcoop-input"/>').val(_value).appendTo(_parent);
		if (_options.maxLength)
			el.attr('maxlength', _options.maxLength);
		if (_options.placeholder)
			el.attr('placeholder', _options.placeholder);
		if (_options.width)
			el.css('width', _options.width);
		if (_options.readOnly)
			el.attr('readonly', 'readonly');
		el.on('keydown', function (_event)
		{
			_event.stopPropagation();
			if (_event.which === 13)
				el.blur();
		});
		if (_onCommit)
			el.on('change', function () { _onCommit(el.val()); });
		return el;
	},

	section: function (_panel, _title)
	{
		var sec = $('<div class="bbcoop-panel-section"/>').appendTo(_panel);
		if (_title)
			$('<div class="bbcoop-menu-heading font-bold"/>').text(_title).appendTo(sec);
		return sec;
	},

	// A row of buttons where one is picked.
	choices: function (_parent, _options, _current, _disabled, _onPick)
	{
		var row = $('<div class="bbcoop-choices"/>').appendTo(_parent);
		$.each(_options, function (_, _o)
		{
			var b = $('<div class="bbcoop-choice"/>').text(_o.label).appendTo(row);
			if (_o.title)
				b.attr('title', _o.title);
			if (_o.value === _current)
				b.addClass('is-picked');
			else if (_disabled)
				b.addClass('is-disabled');
			else
				b.on('click', function () { _onPick(_o.value); });
		});
		return row;
	},

	note: function (_parent, _text, _class)
	{
		return $('<div class="bbcoop-menu-note"/>').addClass(_class || '').text(_text).appendTo(_parent);
	},

	renderPanel: function (_p, _error)
	{
		BBCoop.closePanel();
		BBCoop.closeMenu();
		var connection = Screens.BBCoopConnection;
		connection.createDIV();
		var panel = $('<div class="bbcoop-panel bbcoop-menu text-font-normal"/>').appendTo(connection.mRoot);
		panel.on('mousedown click mousewheel wheel', function (_event) { _event.stopPropagation(); });

		var title = $('<div class="bbcoop-menu-title title-font-big font-bold"/>').text('Co-op').appendTo(panel);
		$('<span class="bbcoop-panel-version text-font-small"/>').text(' v' + _p.version).appendTo(title);
		$('<div class="bbcoop-menu-close">×</div>').appendTo(panel).on('click', BBCoop.closePanel);

		// Status and problems.
		var status = $('<div class="bbcoop-panel-status"/>').addClass('is-' + _p.status.state).appendTo(panel);
		status.append('<span class="bbcoop-light-dot"/>').append($('<span/>').text(_p.status.text));
		var shown = {};
		$.each([_error, _p.error], function (_, _text)
		{
			if (_text && !shown[_text])
			{
				shown[_text] = true;
				$('<div class="bbcoop-panel-error"/>').text(_text).appendTo(panel);
			}
		});

		var online = _p.how === 'host' || _p.how === 'join';
		var state = _p.status.state;
		var connected = state === 'connecting' || state === 'waiting' || state === 'linked';

		// How are you playing?
		var how = BBCoop.section(panel, 'How are you playing?');
		var pick = function (_value) { BBCoop.panelAction({ action: 'setHow', value: _value }); };
		BBCoop.choices(how, [
			{ value: 'alone', label: 'Play alone', title: 'Normal single player. Co-op is off.' },
			{ value: 'host', label: 'Host', title: 'You are Player 1 and run the campaign. Your friend joins you.' },
			{ value: 'join', label: 'Join', title: 'You are Player 2 and join the host\'s campaign.' }
		], _p.how, _p.inBattle, pick);
		if (_p.how === 'hotseat' || _p.how === 'loopback')
			BBCoop.mPanelAdvanced = true;
		if (BBCoop.mPanelAdvanced)
		{
			BBCoop.choices(how, [
				{ value: 'hotseat', label: 'Hot-seat (same PC)', title: 'Both players share this PC and take turns.' },
				{ value: 'loopback', label: 'Loopback test (solo)', title: 'Tests online combat on this PC alone. For development.' }
			], _p.how, _p.inBattle, pick);
		}
		else
		{
			$('<div class="bbcoop-link"/>').text('More options').appendTo(how).on('click', function ()
			{
				BBCoop.mPanelAdvanced = true;
				BBCoop.refreshPanel();
			});
		}
		if (_p.inBattle)
			BBCoop.note(how, 'You can change this after the battle.');

		// Connection.
		if (_p.how === 'host')
		{
			var sec = BBCoop.section(panel, 'Connection');
			var grid = $('<div class="bbcoop-form"/>').appendTo(sec);
			$('<label/>').text('Relay address').appendTo(grid);
			BBCoop.input(grid, _p.address, { placeholder: 'bb.example.com' }, function (_v) { BBCoop.panelAction({ action: 'setAddress', value: _v }); });
			$('<label/>').text('Session key').appendTo(grid);
			BBCoop.input(grid, _p.key, { placeholder: 'the --key the relay uses' }, function (_v) { BBCoop.panelAction({ action: 'setKey', value: _v }); });
			BBCoop.connectButtons(sec, _p, connected);

			$('<div class="bbcoop-menu-heading font-bold"/>').text('Join code for your friend').appendTo(sec);
			var row = $('<div class="bbcoop-menu-row"/>').appendTo(sec);
			var code = BBCoop.input(row, _p.joinCode, { readOnly: true, width: '36.0rem' });
			code.on('focus click', function () { code.select(); });
			BBCoop.button(row, 'Copy', false, function () { BBCoop.copy(code); });
			BBCoop.note(sec, 'Send this to your friend privately: it contains the key.');
			if (_p.joinCodeNote)
				BBCoop.note(sec, _p.joinCodeNote, 'is-warning');
		}
		else if (_p.how === 'join')
		{
			var jsec = BBCoop.section(panel, 'Join code from the host');
			var jrow = $('<div class="bbcoop-menu-row"/>').appendTo(jsec);
			var joinBox = BBCoop.input(jrow, _p.address !== '' ? _p.joinCode : '', { placeholder: 'paste the code here', width: '36.0rem' });
			if (connected)
				BBCoop.button(jrow, 'Disconnect', false, function () { BBCoop.panelAction({ action: 'disconnect' }); });
			else
				BBCoop.button(jrow, 'Join', false, function () { BBCoop.panelAction({ action: 'join', value: joinBox.val() }); });
			if (state === 'linked')
				BBCoop.button(jrow, 'Ping', false, function () { BBCoop.panelAction({ action: 'ping' }); });
			BBCoop.note(jsec, 'The host finds it in their Co-op panel. It looks like bb.example.com/secret.');
		}

		// Players: name, badge, colour.
		if (_p.profiles.length > 0)
		{
			var psec = BBCoop.section(panel, online ? 'You' : 'Players');
			$.each(_p.profiles, function (_, _pr)
			{
				var card = $('<div class="bbcoop-profile"/>').appendTo(psec);
				$('<div class="bbcoop-badge is-preview text-font-small"/>').css('background-color', _pr.color).text(_pr.preview).appendTo(card);
				var form = $('<div class="bbcoop-form"/>').appendTo(card);
				var set = function (_field)
				{
					return function (_v) { BBCoop.panelAction({ action: 'setProfile', player: _pr.player, field: _field, value: _v }); };
				};
				$('<label/>').text(online ? 'Name' : 'Player ' + _pr.player).appendTo(form);
				BBCoop.input(form, _pr.name, { maxLength: 24 }, set('Name'));
				$('<label/>').text('Badge').appendTo(form);
				BBCoop.input(form, _pr.tag, { maxLength: 4, width: '6.0rem' }, set('Tag'));
				$('<label/>').text('Colour').appendTo(form);
				var swatches = $('<div class="bbcoop-swatches"/>').appendTo(form);
				$.each(_p.colors, function (_, _c)
				{
					var sw = $('<div class="bbcoop-swatch"/>').css('background-color', _c.css).appendTo(swatches);
					if (_c.css === _pr.color)
						sw.addClass('is-picked');
					sw.on('click', function () { set('Color')(_c.value); });
				});
			});
			if (online)
				BBCoop.note(psec, 'Your friend sees these on your brothers\' badges.');
		}

		// Brothers and alerts.
		if (_p.how !== 'alone')
		{
			var bsec = BBCoop.section(panel, 'New brothers go to');
			var rules = [];
			$.each(_p.hireRules, function (_, _r) { rules.push({ value: _r, label: _r }); });
			BBCoop.choices(bsec, rules, _p.hireRule, !_p.isAdmin, function (_v) { BBCoop.panelAction({ action: 'setHireRule', value: _v }); });
			if (!_p.isAdmin)
				BBCoop.note(bsec, 'The host decides this.');
			BBCoop.note(bsec, 'In the character screen, click a brother\'s badge to give him to the other player or to retrain him.');

			if (_p.how !== 'hotseat')
			{
				var asec = BBCoop.section(panel, 'Your-turn alert');
				BBCoop.choices(asec, [
					{ value: true, label: 'Sound and flash' },
					{ value: false, label: 'Off' }
				], _p.turnAlert, false, function (_v) { BBCoop.panelAction({ action: 'setTurnAlert', value: _v }); });
			}
		}
	},

	connectButtons: function (_parent, _p, _connected)
	{
		var row = $('<div class="bbcoop-menu-row"/>').appendTo(_parent);
		if (_connected)
			BBCoop.button(row, 'Disconnect', false, function () { BBCoop.panelAction({ action: 'disconnect' }); });
		else
			BBCoop.button(row, 'Connect', false, function () { BBCoop.panelAction({ action: 'connect' }); });
		if (_p.status.state === 'linked')
			BBCoop.button(row, 'Ping', false, function () { BBCoop.panelAction({ action: 'ping' }); });
	},

	copy: function (_input)
	{
		_input.focus().select();
		var ok = false;
		try
		{
			ok = document.execCommand('copy');
		}
		catch (e)
		{
			ok = false;
		}
		Screens.BBCoopConnection.showToast(ok ? 'Join code copied' : 'Press Ctrl+C to copy the selected code');
	},


	trait: function (_parent, _t, _onClick)
	{
		var el = $('<div class="bbcoop-trait"/>').attr('title', _t.name).appendTo(_parent);
		el.append($('<img/>').attr('src', Path.GFX + _t.icon));
		el.append($('<span/>').text(_t.name));
		el.on('click', function () { _onClick(el); });
	}
};

(function ()
{
	var proto = CharacterScreenBrothersListModule.prototype;

	var addBrotherSlotDIV = proto.addBrotherSlotDIV;
	proto.addBrotherSlotDIV = function (_parentDiv, _data, _index, _allowReordering)
	{
		var ret = addBrotherSlotDIV.call(this, _parentDiv, _data, _index, _allowReordering);
		BBCoop.addBadge(this.mListScrollContainer.find('#slot-index_' + _data[CharacterScreenIdentifier.Entity.Id] + ':first'), _data);
		return ret;
	};

	var updateBrotherSlot = proto.updateBrotherSlot;
	proto.updateBrotherSlot = function (_data)
	{
		var ret = updateBrotherSlot.call(this, _data);
		BBCoop.addBadge(this.mListScrollContainer.find('#slot-index_' + _data[CharacterScreenIdentifier.Entity.Id] + ':first'), _data);
		return ret;
	};
})();

// Turn order bar in combat: grey out the other player's brothers.
(function ()
{
	var proto = TacticalScreenTurnSequenceBarModule.prototype;
	var mark = function (_module, _data)
	{
		if (_data === null || _data === undefined || _data.id === null)
			return;
		var found = _module.findEntityDIV(_data.id);
		if (found !== null)
			BBCoop.markOwnership(found.div, _data);
	};

	var addEntity = proto.addEntity;
	proto.addEntity = function (_data)
	{
		var ret = addEntity.call(this, _data);
		mark(this, _data);
		return ret;
	};

	var updateEntity = proto.updateEntity;
	proto.updateEntity = function (_data)
	{
		var ret = updateEntity.call(this, _data);
		mark(this, _data);
		return ret;
	};
})();

// ---- Main menu: Solo / Host / Join, then New or Load ---------------------------
// First screen: Solo Campaign, Host Campaign, Join Campaign, Options, Tutorial Videos,
// Credits, Quit. Solo goes straight to New/Load/Scenarios. Host and Join show a lobby
// that connects the two players. Starting a campaign while linked plays it together;
// starting one while not linked plays it solo (see "beforeCampaign").
// Reuses the game's own buttons and only regroups them, so their behaviour stays the game's.

BBCoop.splitMainMenu = function (_module)
{
	var container = _module.mButtonContainer;
	var rows = container.children('.row');
	// The game's order: New Campaign, Load Campaign, Scenarios, Options, Tutorial Videos, Credits, Quit.
	// If another mod changed the menu, leave it alone.
	if (rows.length !== 7)
		return;

	var step = _module.mBBCoopStep || 'start';
	var campaignRows = rows.slice(0, 3);
	var otherRows = rows.slice(3, 7);

	var addButton = function (_text, _onClick, _atTop)
	{
		var row = $('<div class="row"/>');
		var layout = $('<div class="l-center"/>').appendTo(row);
		layout.createTextButton(_text, _onClick, '', 4);
		if (_atTop)
			container.prepend(row);
		else
			container.append(row);
		return row;
	};

	var goTo = function (_step)
	{
		_module.mBBCoopStep = _step;
		_module.createMainMenuButtons();
	};

	if (step === 'start')
	{
		campaignRows.hide();
		// prepend in reverse so they end up in this order
		addButton("Join Campaign", function () { goTo('join'); BBCoop.lobbyAction({ action: 'enterLobby', value: 'join' }); }, true);
		addButton("Host Campaign", function () { goTo('host'); BBCoop.lobbyAction({ action: 'enterLobby', value: 'host' }); }, true);
		addButton("Solo Campaign", function () { goTo('solo'); BBCoop.lobbyAction({ action: 'enterLobby', value: 'alone' }); }, true);
		return;
	}

	otherRows.hide();
	var back = function ()
	{
		if (step !== 'solo')
			BBCoop.lobbyAction({ action: 'leaveLobby' });
		goTo('start');
	};

	if (step === 'solo')
	{
		addButton("Back", back, false);
		return;
	}

	// Host or Join lobby.
	container.prepend($('<div class="row bbcoop-lobby"/>').attr('data-step', step));
	addButton("Back", back, false);
	BBCoop.refreshLobby();
};

BBCoop.refreshLobby = function ()
{
	var connection = Screens.BBCoopConnection;
	if ($('.bbcoop-lobby').length === 0 || connection.mSQHandle === null)
		return;
	SQ.call(connection.mSQHandle, "onQueryPanel", null, function (_ret)
	{
		if (_ret && _ret.panel)
			BBCoop.renderLobby(_ret.panel);
	});
};

BBCoop.lobbyAction = function (_args)
{
	var connection = Screens.BBCoopConnection;
	if (connection.mSQHandle === null)
		return;
	SQ.call(connection.mSQHandle, "onPanelAction", _args, function (_ret)
	{
		if (!_ret || !_ret.panel)
			return;
		if (_ret.error)
			connection.showToast(_ret.error);
		BBCoop.renderLobby(_ret.panel);
		if (BBCoop.isPanelOpen())
			BBCoop.renderPanel(_ret.panel, _ret.error);
	});
};

BBCoop.renderLobby = function (_p)
{
	var row = $('.bbcoop-lobby');
	if (row.length === 0)
		return;
	var step = row.attr('data-step');
	var state = _p.status.state;
	var linked = state === 'linked';
	var connected = linked || state === 'waiting' || state === 'connecting';

	// Keep a half-typed join code if the lobby redraws while the player types.
	var typing = row.find('input:focus').length > 0;
	if (typing)
		return;
	row.empty();

	$('<div class="bbcoop-lobby-title title-font-big font-bold"/>').text(step === 'host' ? 'Host a campaign' : 'Join a campaign').appendTo(row);

	var line = $('<div class="bbcoop-lobby-status text-font-normal"/>').addClass('is-' + state).appendTo(row);
	$('<span class="bbcoop-light-dot"/>').appendTo(line);
	var text;
	if (linked)
		text = step === 'host' ? 'Linked with ' + _p.status.short + '. Start or load a campaign to play together.' : 'Linked with ' + _p.status.short + '. Load the same save as the host to play together.';
	else if (state === 'waiting')
		text = step === 'host' ? 'Waiting for your friend to join... (Starting now plays solo.)' : 'Connected. Waiting for the host... (Starting now plays solo.)';
	else if (state === 'connecting')
		text = 'Connecting...';
	else
		text = _p.error ? _p.error : (step === 'host' ? 'Not connected.' : 'Paste the join code from the host.');
	$('<span/>').text(text).appendTo(line);

	if (step === 'host')
	{
		if (!linked)
		{
			var codeRow = $('<div class="bbcoop-lobby-line"/>').appendTo(row);
			$('<span class="bbcoop-lobby-label"/>').text('Join code: ').appendTo(codeRow);
			var code = BBCoop.input(codeRow, _p.joinCode, { readOnly: true, width: '22.0rem' });
			code.on('focus click', function () { code.select(); });
			BBCoop.button(codeRow, 'Copy', false, function () { BBCoop.copy(code); });
			if (_p.joinCodeNote)
				$('<div class="bbcoop-lobby-note is-warning"/>').text('This code only works on your own PC. Set the relay address in Co-op settings.').appendTo(row);
		}
		if (!connected)
			BBCoop.button($('<div class="bbcoop-lobby-line"/>').appendTo(row), 'Connect', false, function () { BBCoop.lobbyAction({ action: 'connect' }); });
	}
	else if (!connected)
	{
		var joinRow = $('<div class="bbcoop-lobby-line"/>').appendTo(row);
		var box = BBCoop.input(joinRow, _p.address !== '' ? _p.joinCode : '', { placeholder: 'paste the join code', width: '22.0rem' });
		BBCoop.button(joinRow, 'Join', false, function () { BBCoop.lobbyAction({ action: 'join', value: box.val() }); });
	}

	$('<span class="bbcoop-link"/>').text('Co-op settings').appendTo($('<div class="bbcoop-lobby-line"/>').appendTo(row)).on('click', function ()
	{
		BBCoop.panelCall("onQueryPanel", null);
	});

};

(function ()
{
	var proto = MainMenuModule.prototype;

	var createMainMenuButtons = proto.createMainMenuButtons;
	proto.createMainMenuButtons = function ()
	{
		var ret = createMainMenuButtons.call(this);
		BBCoop.splitMainMenu(this);
		return ret;
	};

	// New, Load and Scenarios: first let the scripts decide solo or together
	// (together only if linked with the other player), then carry on as normal.
	$.each(['notifyBackendNewCampaignButtonPressed', 'notifyBackendLoadCampaignButtonPressed', 'notifyBackendScenariosButtonPressed'], function (_, _name)
	{
		var original = proto[_name];
		proto[_name] = function ()
		{
			var self = this;
			var args = arguments;
			var connection = Screens.BBCoopConnection;
			// Only from the main menu, not the in-game pause menu's Load button.
			var inGame = self.mContainer && (self.mContainer.hasClass('is-world-map') || self.mContainer.hasClass('is-tactical-map'));
			if (connection.mSQHandle === null || inGame)
				return original.apply(self, args);
			SQ.call(connection.mSQHandle, "onPanelAction", { action: 'beforeCampaign' }, function ()
			{
				original.apply(self, args);
			});
		};
	});

	// Coming back to the main menu (after quitting a campaign) starts at the first screen.
	var showMainMenu = proto.showMainMenu;
	proto.showMainMenu = function (_withAnimation)
	{
		this.mBBCoopStep = 'start';
		return showMainMenu.call(this, _withAnimation);
	};
})();
