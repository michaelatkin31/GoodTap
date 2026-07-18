defmodule GoodtapWeb.GameLive do
  use GoodtapWeb, :live_view

  alias Goodtap.{Games, Catalog, Decks, Accounts}
  alias Goodtap.GameEngine.{Actions, State}
  alias GoodtapWeb.Hotkeys

  def mount(%{"id" => id}, _session, socket) do
    case Games.get_game(id) do
      nil ->
        {:ok, push_navigate(socket, to: ~p"/games")}

      game ->
        mount_game(game, socket)
    end
  end

  defp mount_game(game, socket) do
    user = socket.assigns.current_scope.user

    my_role = Games.player_key_for(game, user.id)

    # Verify user is in this game
    unless my_role do
      {:ok, push_navigate(socket, to: ~p"/games")}
    else
      opponent_roles = Games.player_keys(game) |> Enum.reject(&(&1 == my_role))
      viewed_opponent = List.first(opponent_roles)

      game_state = game.game_state || %{}

      Games.subscribe_to_game(game.id)

      sideboarding = game.status == "sideboarding"
      deck_id = get_in(game_state, [my_role, "deck_id"])
      sideboard_deck = if sideboarding && deck_id, do: Decks.get_deck_with_cards!(deck_id), else: nil

      # Die roll is shown once per player per game. Dismissal is saved to game_state
      # under "die_roll_dismissed" so it survives page reloads. Die roll only exists
      # on first game start — sideboard restarts do not generate one (roll_die: false).
      die_roll_dismissed = get_in(game_state, ["die_roll_dismissed", my_role]) == true
      show_die_roll = map_size(game_state) > 0 && is_map(game_state["die_roll"]) && !die_roll_dismissed

      {:ok,
       assign(socket,
         game: game,
         game_state: game_state,
         my_role: my_role,
         opponent_roles: opponent_roles,
         viewed_opponent: viewed_opponent,
         page_title: "Game",
         # UI state
         open_zone: nil,
         context_menu: nil,
         # Scry
         scry_session: nil,
         # Token search
         token_search: nil,
         token_place_x: 0.1,
         token_place_y: 0.5,
         token_filter: :tokens_only,
         recent_tokens: user.recent_tokens,
         # Add counter
         adding_counter_to: nil,
         counter_name_input: "", counter_has_quantity: true,
         recent_counters: user.recent_counters,
         # End game
         end_game_modal: false,
         # Die roll modal
         die_roll_modal: show_die_roll,
         # Sideboarding
         sideboard_modal: sideboarding,
         sideboard_deck: sideboard_deck,
         sideboard_card_map: sideboard_card_map(sideboard_deck),
         sideboard_pending: [],
         # Multi-card selection
         selected_cards: MapSet.new(),
         # Game log
         log_open: false,
         # Pending log entries for debouncing rapid counter changes.
         # Map of key => %{message_fn: fn(delta) -> string, delta: int, timer: ref}
         # Flushed after 1s of inactivity per key.
         pending_log: %{}
       )}
    end
  end

  # ─── PubSub Handlers ──────────────────────────────────────────────────────

  def handle_info({:game_state_updated, new_state}, socket) do
    {:noreply, assign(socket, game_state: new_state)}
  end

  def handle_info({:game_updated, game}, socket) do
    {:noreply, assign(socket, game: game)}
  end

  def handle_info(:game_ended, socket) do
    {:noreply,
     socket
     |> put_flash(:info, "The game has ended.")
     |> push_navigate(to: ~p"/games")}
  end

  def handle_info({:sideboarding_started, game}, socket) do
    sideboard_deck = build_sideboard_deck(game.game_state, socket.assigns.my_role)
    opponent_roles = Games.player_keys(game) |> Enum.reject(&(&1 == socket.assigns.my_role))
    viewed_opponent = socket.assigns.viewed_opponent || List.first(opponent_roles)
    {:noreply, assign(socket, game: game, game_state: game.game_state, sideboard_modal: true, sideboard_deck: sideboard_deck, sideboard_card_map: sideboard_card_map(sideboard_deck), sideboard_pending: [], opponent_roles: opponent_roles, viewed_opponent: viewed_opponent)}
  end

  def handle_info({:game_restarted, game}, socket) do
    opponent_roles = Games.player_keys(game) |> Enum.reject(&(&1 == socket.assigns.my_role))
    viewed_opponent = socket.assigns.viewed_opponent || List.first(opponent_roles)
    {:noreply,
     socket
     |> assign(game: game, game_state: game.game_state, sideboard_modal: false, sideboard_pending: [], end_game_modal: false, opponent_roles: opponent_roles, viewed_opponent: viewed_opponent)
     |> put_flash(:info, "New game started!")}
  end

  def handle_info({:token_selected, %{"card_id" => card_id} = params}, socket) do
    card = Catalog.get_card!(card_id)
    printing_id = params["printing_id"]
    x = socket.assigns.token_place_x
    y = socket.assigns.token_place_y

    socket =
      apply_action_inline(socket, fn state, player ->
        with {:ok, new_state} <- Actions.create_token(state, player, card, x, y, printing_id) do
          {:ok, append_log(new_state, player, "created #{card.name} token")}
        end
      end)

    user = socket.assigns.current_scope.user
    updated_user = Accounts.add_recent_token(user, card, printing_id)
    updated_scope = %{socket.assigns.current_scope | user: updated_user}

    {:noreply, assign(socket, token_search: nil, recent_tokens: updated_user.recent_tokens, current_scope: updated_scope)}
  end

  def handle_info({:flush_log, key}, socket) do
    pending = socket.assigns.pending_log
    case Map.get(pending, key) do
      nil -> {:noreply, socket}
      %{delta: delta, message_fn: message_fn} ->
        message = message_fn.(delta, socket.assigns.game_state, socket.assigns.my_role)
        new_state = append_log(socket.assigns.game_state, socket.assigns.my_role, message)
        {:ok, _} = Games.update_game_state(socket.assigns.game, new_state)
        Games.broadcast_game_state(socket.assigns.game.id, new_state)
        {:noreply, assign(socket, game_state: new_state, pending_log: Map.delete(pending, key))}
    end
  end

  def handle_info({:target_card, instance_id}, socket) do
    {:noreply, push_event(socket, "target_card", %{instance_id: instance_id})}
  end

  def handle_info(_, socket), do: {:noreply, socket}

  # ─── Context Menu ─────────────────────────────────────────────────────────

  def handle_event("context_menu", params, socket) do
    instance_id = params["instance_id"]
    zone = params["zone"]
    x = params["x"]
    y_from_bottom = params["y_from_bottom"]
    owner = params["owner"]

    actions =
      cond do
        owner && owner != socket.assigns.my_role && zone == "battlefield" ->
          card = instance_id && get_in(socket.assigns.game_state, [owner, "zones", "battlefield"])
            |> Kernel.||([])
            |> Enum.find(&(&1["instance_id"] == instance_id))
          actions = Hotkeys.valid_actions_for_opponent_battlefield()
          if card && card["is_face_down"], do: actions -- [:copy_opponent_card], else: actions
        owner && owner != socket.assigns.my_role && zone == "hand" ->
          []
        true ->
          Hotkeys.valid_actions_for(zone)
      end

    top_revealed = get_in(socket.assigns.game_state, [socket.assigns.my_role, "top_revealed"]) || false

    context_menu = %{
      instance_id: instance_id,
      zone: zone,
      x: x,
      y_from_bottom: y_from_bottom,
      actions: actions,
      scry_count: 1,
      top_revealed: top_revealed,
    }

    {:noreply, assign(socket, context_menu: context_menu)}
  end

  def handle_event("close_context_menu", _params, socket) do
    {:noreply, assign(socket, context_menu: nil)}
  end

  def handle_event("toggle_log", _params, socket) do
    {:noreply, assign(socket, log_open: !socket.assigns.log_open)}
  end

  # ─── Multi-Card Selection ─────────────────────────────────────────────────

  def handle_event("clear_selection", _params, socket) do
    {:noreply, assign(socket, selected_cards: MapSet.new())}
  end

  def handle_event("set_selection", %{"instance_ids" => ids}, socket) do
    {:noreply, assign(socket, selected_cards: MapSet.new(ids))}
  end

  def handle_event("adjust_scry_count", %{"delta" => delta}, socket) do
    case socket.assigns.context_menu do
      nil -> {:noreply, socket}
      menu ->
        new_count = max(1, min(20, menu.scry_count + String.to_integer(delta)))
        {:noreply, assign(socket, context_menu: %{menu | scry_count: new_count})}
    end
  end

  # ─── Keyboard Shortcuts ───────────────────────────────────────────────────

  def handle_event("hotkey", %{"key" => key, "instance_id" => id, "zone" => zone} = params, socket) do
    owner = params["owner"]
    my_role = socket.assigns.my_role
    viewed_opponent = socket.assigns.viewed_opponent
    selected = socket.assigns.selected_cards
    has_selection = not MapSet.equal?(selected, MapSet.new())
    is_my_card = not is_nil(id) and owner == my_role

    is_find_mode = match?({_, _, %{find: true}}, socket.assigns.open_zone)
    zone_popup_open = socket.assigns.open_zone != nil

    valid_actions =
      cond do
        is_find_mode and is_my_card -> [:move_to_graveyard, :move_to_exile, :move_to_hand, :move_to_deck_top, :move_to_deck_bottom, :move_to_battlefield]
        zone_popup_open and zone == "deck" and is_my_card -> Hotkeys.valid_actions_for("deck") ++ [:move_to_deck_top, :move_to_deck_bottom, :move_to_hand, :move_to_graveyard, :move_to_exile, :move_to_battlefield]
        is_my_card -> Hotkeys.valid_actions_for(zone)
        true -> []
      end
    valid_opponent_actions = if not is_nil(id) and owner != nil and owner != my_role, do: Hotkeys.valid_actions_for_opponent_battlefield(), else: []
    action_allowed? = fn action -> action in valid_actions or action in valid_opponent_actions end

    k = Hotkeys
    sel_names = fn st, p -> Enum.map(MapSet.to_list(selected), &card_name_from_state(st, p, &1)) |> Enum.join(", ") end

    cond do
      # ── Multi-selection actions (battlefield only) ──────────────────────
      has_selection and key == k.key_for(:move_to_graveyard) ->
        apply_to_selection(socket,
          fn st, p, sid -> Actions.move_to_graveyard(st, p, sid, "battlefield") end,
          fn st, p -> "#{sel_names.(st, p)} → graveyard" end)

      has_selection and key == k.key_for(:move_to_exile) ->
        apply_to_selection(socket,
          fn st, p, sid -> Actions.move_to_exile(st, p, sid, "battlefield") end,
          fn st, p -> "#{sel_names.(st, p)} → exile" end)

      has_selection and key == k.key_for(:move_to_deck_top) ->
        apply_to_selection(socket,
          fn st, p, sid -> Actions.move_to_deck(st, p, sid, "battlefield") end,
          fn st, p -> "#{sel_names.(st, p)} → deck (top)" end)

      has_selection and key == k.key_for(:move_to_deck_bottom) ->
        apply_to_selection(socket,
          fn st, p, sid -> Actions.move_to_deck_bottom(st, p, sid, "battlefield") end,
          fn st, p -> "#{sel_names.(st, p)} → deck (bottom)" end)

      has_selection and key == k.key_for(:move_to_hand) ->
        apply_to_selection(socket,
          fn st, p, sid -> Actions.move_to_hand(st, p, sid, "battlefield") end,
          fn st, p -> "#{sel_names.(st, p)} → hand" end)

      has_selection and key == k.key_for(:flip_card) ->
        apply_to_selection(socket,
          fn st, p, sid -> Actions.flip_card(st, p, sid, "battlefield") end,
          fn st, p -> "flipped #{sel_names.(st, p)}" end)

      has_selection and key == k.key_for(:tap) ->
        apply_to_selection(socket, fn st, p, sid -> Actions.tap(st, p, sid) end, nil)

      true ->
        cond do
          # ── Deck top-card shortcuts ────────────────────────────────────
          key == k.key_for(:move_to_graveyard) and :draw_top_to in valid_actions and not is_find_mode ->
            apply_action(socket, fn st, p ->
              top = List.first(get_in(st, [p, "zones", "deck"]) || [])
              with {:ok, new_st} <- Actions.draw_top_to(st, p, "graveyard") do
                {:ok, append_log(new_st, p, "#{top["name"] || "top card"} → graveyard")}
              end
            end)

          key == k.key_for(:move_to_exile) and :draw_top_to in valid_actions and not is_find_mode ->
            apply_action(socket, fn st, p ->
              top = List.first(get_in(st, [p, "zones", "deck"]) || [])
              with {:ok, new_st} <- Actions.draw_top_to(st, p, "exile") do
                {:ok, append_log(new_st, p, "#{top["name"] || "top card"} → exile")}
              end
            end)

          key == k.key_for(:move_to_battlefield) and :draw_top_to in valid_actions and not is_find_mode ->
            apply_action(socket, fn st, p ->
              top = List.first(get_in(st, [p, "zones", "deck"]) || [])
              with {:ok, new_st} <- Actions.draw_top_to(st, p, "battlefield") do
                {:ok, append_log(new_st, p, "#{top["name"] || "top card"} → battlefield")}
              end
            end)

          key == k.key_for(:move_to_hand) and :draw_top_to in valid_actions and not is_find_mode ->
            apply_action(socket, fn st, p ->
              top = List.first(get_in(st, [p, "zones", "deck"]) || [])
              name = if top && all_know?(st, top), do: top["name"], else: "a card"
              with {:ok, new_st} <- Actions.draw_top_to(st, p, "hand") do
                {:ok, append_log(new_st, p, "#{name} → hand")}
              end
            end)

          # ── Single-card actions ────────────────────────────────────────
          # For pile zones (graveyard/exile/deck), resolve_pile_id always uses the
          # current top card so rapid keypresses each act on a different card.
          # Exception: in find mode the user is hovering a specific card, use it directly.
          key == k.key_for(:move_to_graveyard) and not is_nil(id) and :move_to_graveyard in valid_actions ->
            apply_action(socket, fn st, p ->
              eid = resolve_pile_id(st, p, zone, id, zone_popup_open)
              with {:ok, new_st} <- Actions.move_to_graveyard(st, p, eid, zone) do
                {:ok, append_log(new_st, p, "#{card_name_from_state(new_st, p, eid)} → graveyard")}
              end
            end)

          key == k.key_for(:move_to_exile) and not is_nil(id) and :move_to_exile in valid_actions ->
            apply_action(socket, fn st, p ->
              eid = resolve_pile_id(st, p, zone, id, zone_popup_open)
              with {:ok, new_st} <- Actions.move_to_exile(st, p, eid, zone) do
                {:ok, append_log(new_st, p, "#{card_name_from_state(new_st, p, eid)} → exile")}
              end
            end)

          key == k.key_for(:flip_card) and not is_nil(id) and :flip_card in valid_actions ->
            apply_action(socket, fn st, p ->
              with {:ok, new_st} <- Actions.flip_card(st, p, id, zone) do
                {:ok, append_log(new_st, p, "flipped #{card_name_from_state(new_st, p, id)}")}
              end
            end)

          key == k.key_for(:tap) and not is_nil(id) and :tap in valid_actions ->
            apply_action(socket, fn st, p ->
              card = find_card_in_zone(st, p, "battlefield", id)
              verb = if card && card["tapped"], do: "untapped", else: "tapped"
              with {:ok, new_st} <- Actions.tap(st, p, id) do
                {:ok, append_log(new_st, p, "#{verb} #{card_name_from_state(new_st, p, id)}")}
              end
            end)

          key == k.key_for(:move_to_deck_top) and not is_nil(id) and :move_to_deck_top in valid_actions ->
            apply_action(socket, fn st, p ->
              eid = resolve_pile_id(st, p, zone, id, zone_popup_open)
              with {:ok, new_st} <- Actions.move_to_deck(st, p, eid, zone) do
                {:ok, append_log(new_st, p, "#{card_name_from_state(new_st, p, eid)} → deck (top)")}
              end
            end)

          key == k.key_for(:move_to_deck_bottom) and not is_nil(id) and :move_to_deck_bottom in valid_actions ->
            apply_action(socket, fn st, p ->
              eid = resolve_pile_id(st, p, zone, id, zone_popup_open)
              with {:ok, new_st} <- Actions.move_to_deck_bottom(st, p, eid, zone) do
                {:ok, append_log(new_st, p, "#{card_name_from_state(new_st, p, eid)} → deck (bottom)")}
              end
            end)

          key == k.key_for(:move_to_hand) and not is_nil(id) and :move_to_hand in valid_actions ->
            apply_action(socket, fn st, p ->
              eid = resolve_pile_id(st, p, zone, id, zone_popup_open)
              with {:ok, new_st} <- Actions.move_to_hand(st, p, eid, zone) do
                {:ok, append_log(new_st, p, "#{card_name_from_state(new_st, p, eid)} → hand")}
              end
            end)

          key == k.key_for(:move_to_battlefield) and not is_nil(id) and :move_to_battlefield in valid_actions ->
            apply_action(socket, fn st, p ->
              eid = resolve_pile_id(st, p, zone, id, zone_popup_open)
              with {:ok, new_st} <- Actions.move_to_battlefield(st, p, eid, zone, 0.5, 0.5) do
                {:ok, append_log(new_st, p, "#{card_name_from_state(new_st, p, eid)} → battlefield")}
              end
            end)

          key == k.key_for(:add_counter) and not is_nil(id) and :add_counter in valid_actions ->
            {:noreply, assign(socket, adding_counter_to: id, counter_name_input: "", counter_has_quantity: true)}

          key == k.key_for(:copy_card) and not is_nil(id) and action_allowed?.(:copy_card) ->
            if owner == my_role do
              apply_action(socket, fn st, p ->
                with {:ok, new_st} <- Actions.copy_card(st, p, id) do
                  {:ok, append_log(new_st, p, "copied #{card_name_from_state(new_st, p, id)}")}
                end
              end)
            else
              src = owner || viewed_opponent
              apply_action(socket, fn st, p ->
                with {:ok, new_st} <- Actions.copy_opponent_card(st, p, src, id) do
                  opp_name = card_name_from_state(new_st, src, id)
                  {:ok, append_log(new_st, p, "copied #{opp_name}")}
                end
              end)
            end

          key == k.key_for(:target_card) and not is_nil(id) and action_allowed?.(:target_card) ->
            Games.broadcast_target_card(socket.assigns.game.id, id)
            {:noreply, socket}

          # ── Global actions ─────────────────────────────────────────────
          key == k.key_for(:shuffle) ->
            apply_action(socket, fn st, p ->
              with {:ok, new_st} <- Actions.shuffle(st, p) do
                {:ok, append_log(new_st, p, "shuffled their deck")}
              end
            end)

          key == k.key_for(:untap_all) ->
            apply_action(socket, fn st, p ->
              with {:ok, new_st} <- Actions.untap_all(st, p) do
                {:ok, append_log(new_st, p, "untapped all")}
              end
            end)

          key == k.key_for(:new_turn) ->
            apply_action(socket, fn st, p ->
              with {:ok, st1} <- Actions.untap_all(st, p),
                   {:ok, st2} <- Actions.draw(st1, p, 1) do
                {:ok, append_log(st2, p, "untapped all and drew a card")}
              end
            end)

          key == k.key_for(:create_token) ->
            {:noreply, assign(socket, token_search: true)}

          key == k.key_for(:draw_face_down) and zone in ["deck", "deck_top"] ->
            apply_action(socket, fn st, p ->
              with {:ok, new_st} <- Actions.draw_face_down(st, p) do
                {:ok, append_log(new_st, p, "drew a card face down")}
              end
            end)

          key == k.key_for(:draw_one) ->
            apply_action(socket, fn st, p ->
              with {:ok, new_st} <- Actions.draw(st, p, 1) do
                {:ok, append_log(new_st, p, "drew a card")}
              end
            end)

          key in ["1", "2", "3", "4", "5", "6", "7", "8", "9"] ->
            count = String.to_integer(key)
            apply_action(socket, fn st, p ->
              with {:ok, new_st} <- Actions.draw(st, p, count) do
                {:ok, append_log(new_st, p, "drew #{count} cards")}
              end
            end)

          true ->
            {:noreply, socket}
        end
    end
  end

  # ─── Card Actions ─────────────────────────────────────────────────────────

  def handle_event("action", %{"type" => "add_counter", "instance_id" => id}, socket) do
    {:noreply, assign(socket, adding_counter_to: id, counter_name_input: "", counter_has_quantity: true, context_menu: nil)}
  end

  def handle_event("action", %{"type" => "tap", "instance_id" => id}, socket) do
    apply_action(socket, fn state, player ->
      card = find_card_in_zone(state, player, "battlefield", id)
      verb = if card && card["tapped"], do: "untapped", else: "tapped"
      with {:ok, new_state} <- Actions.tap(state, player, id) do
        {:ok, append_log(new_state, player, "#{verb} #{card_name_from_state(new_state, player, id)}")}
      end
    end)
  end

  def handle_event("action", %{"type" => "move_to_graveyard", "instance_id" => id, "zone" => zone}, socket) do
    apply_action(socket, fn state, player ->
      with {:ok, new_state} <- Actions.move_to_graveyard(state, player, id, zone) do
        {:ok, append_log(new_state, player, "#{card_name_from_state(new_state, player, id)} → graveyard")}
      end
    end)
  end

  def handle_event("action", %{"type" => "move_to_exile", "instance_id" => id, "zone" => zone}, socket) do
    apply_action(socket, fn state, player ->
      with {:ok, new_state} <- Actions.move_to_exile(state, player, id, zone) do
        {:ok, append_log(new_state, player, "#{card_name_from_state(new_state, player, id)} → exile")}
      end
    end)
  end

  def handle_event("action", %{"type" => "move_to_hand", "instance_id" => id, "zone" => zone}, socket) do
    apply_action(socket, fn state, player ->
      with {:ok, new_state} <- Actions.move_to_hand(state, player, id, zone) do
        {:ok, append_log(new_state, player, "#{card_name_from_state(new_state, player, id)} → hand")}
      end
    end)
  end

  def handle_event("action", %{"type" => "move_to_deck_top", "instance_id" => id, "zone" => zone}, socket) do
    apply_action(socket, fn state, player ->
      with {:ok, new_state} <- Actions.move_to_deck(state, player, id, zone) do
        {:ok, append_log(new_state, player, "#{card_name_from_state(new_state, player, id)} → deck (top)")}
      end
    end)
  end

  def handle_event("action", %{"type" => "move_to_deck_bottom", "instance_id" => id, "zone" => zone}, socket) do
    apply_action(socket, fn state, player ->
      with {:ok, new_state} <- Actions.move_to_deck_bottom(state, player, id, zone) do
        {:ok, append_log(new_state, player, "#{card_name_from_state(new_state, player, id)} → deck (bottom)")}
      end
    end)
  end

  def handle_event("action", %{"type" => "flip_card", "instance_id" => id, "zone" => zone}, socket) do
    apply_action(socket, fn state, player ->
      with {:ok, new_state} <- Actions.flip_card(state, player, id, zone) do
        {:ok, append_log(new_state, player, "flipped #{card_name_from_state(new_state, player, id)}")}
      end
    end)
  end

  def handle_event("action", %{"type" => "copy_card", "instance_id" => id}, socket) do
    apply_action(socket, fn state, player ->
      with {:ok, new_state} <- Actions.copy_card(state, player, id) do
        {:ok, append_log(new_state, player, "copied #{card_name_from_state(new_state, player, id)}")}
      end
    end)
  end

  def handle_event("action", %{"type" => "copy_opponent_card", "instance_id" => id} = params, socket) do
    source = params["owner"] || socket.assigns.viewed_opponent
    apply_action(socket, fn state, player ->
      with {:ok, new_state} <- Actions.copy_opponent_card(state, player, source, id) do
        opp_name = card_name_from_state(new_state, source, id)
        {:ok, append_log(new_state, player, "copied #{opp_name}")}
      end
    end)
  end

  def handle_event("action", %{"type" => "target_card", "instance_id" => id}, socket) do
    Games.broadcast_target_card(socket.assigns.game.id, id)
    {:noreply, assign(socket, context_menu: nil)}
  end

  def handle_event("action", %{"type" => "draw_face_down"}, socket) do
    apply_action(socket, fn state, player ->
      with {:ok, new_state} <- Actions.draw_face_down(state, player) do
        {:ok, append_log(new_state, player, "drew a card face down")}
      end
    end)
  end

  def handle_event("action", %{"type" => "draw_top_to", "dest" => dest}, socket)
      when dest in ["battlefield", "battlefield_face_down", "graveyard", "exile", "hand"] do
    apply_action(socket, fn state, player ->
      top = List.first(get_in(state, [player, "zones", "deck"]) || [])
      already_public = top && all_know?(state, top)
      name = (top && top["name"]) || "top card"

      with {:ok, new_state} <- Actions.draw_top_to(state, player, dest) do
        label = case dest do
          "battlefield"          -> "#{name} → battlefield"
          "battlefield_face_down" -> "#{if already_public, do: name, else: "a card"} → battlefield (face down)"
          "graveyard"            -> "#{name} → graveyard"
          "exile"                -> "#{name} → exile"
          "hand"                 -> "#{if already_public, do: name, else: "a card"} → hand"
        end
        {:ok, append_log(new_state, player, label)}
      end
    end)
  end

  def handle_event("action", %{"type" => "find_card"}, socket) do
    player = socket.assigns.my_role
    {:noreply, assign(socket, open_zone: {player, "deck", %{find: true, query: ""}}, context_menu: nil)}
  end

  def handle_event("action", %{"type" => "move_all_to_exile"}, socket) do
    apply_action(socket, fn state, player ->
      with {:ok, new_state} <- Actions.move_all_to_exile(state, player) do
        {:ok, append_log(new_state, player, "moved graveyard to exile")}
      end
    end)
  end

  def handle_event("action", %{"type" => "shuffle"}, socket) do
    apply_action(socket, fn state, player ->
      with {:ok, new_state} <- Actions.shuffle(state, player) do
        {:ok, append_log(new_state, player, "shuffled their deck")}
      end
    end)
  end

  def handle_event("action", %{"type" => "toggle_top_revealed"}, socket) do
    apply_action(socket, fn state, player ->
      with {:ok, new_state} <- Actions.toggle_top_revealed(state, player) do
        enabled = get_in(new_state, [player, "top_revealed"]) || false
        msg = if enabled, do: "revealed the top of their deck", else: "stopped revealing the top of their deck"
        {:ok, append_log(new_state, player, msg)}
      end
    end)
  end

  def handle_event("action", %{"type" => "mulligan"}, socket) do
    apply_action(socket, fn state, player ->
      with {:ok, new_state} <- Actions.mulligan(state, player) do
        {:ok, append_log(new_state, player, "took a mulligan")}
      end
    end)
  end

  def handle_event("hand_menu", %{"x" => x, "y_from_bottom" => y_from_bottom}, socket) do
    context_menu = %{instance_id: nil, zone: nil, x: x, y_from_bottom: y_from_bottom, actions: [:mulligan, :reveal_hand, :hide_hand], scry_count: 1}
    {:noreply, assign(socket, context_menu: context_menu)}
  end

  def handle_event("action", %{"type" => "reveal_hand"}, socket) do
    player = socket.assigns.my_role
    hand = get_in(socket.assigns.game_state, [player, "zones", "hand"]) || []
    instance_ids = Enum.map(hand, & &1["instance_id"])
    apply_action(socket, fn state, _p ->
      with {:ok, new_state} <- Actions.reveal_cards(state, player, instance_ids) do
        {:ok, append_log(new_state, player, "revealed their hand")}
      end
    end)
  end

  def handle_event("action", %{"type" => "hide_hand"}, socket) do
    player = socket.assigns.my_role
    apply_action(socket, fn state, _p ->
      with {:ok, new_state} <- Actions.hide_hand(state, player) do
        {:ok, append_log(new_state, player, "hid their hand")}
      end
    end)
  end

  def handle_event("action", %{"type" => "reveal_card", "instance_id" => id}, socket) do
    player = socket.assigns.my_role
    name = get_in(socket.assigns.game_state, [player, "zones", "hand"])
      |> Kernel.||([])
      |> Enum.find(&(&1["instance_id"] == id))
      |> then(&(&1 && &1["name"] || "a card"))
    apply_action(socket, fn state, _p ->
      with {:ok, new_state} <- Actions.reveal_cards(state, player, [id]) do
        {:ok, append_log(new_state, player, "revealed #{name}")}
      end
    end)
  end

  def handle_event("action", %{"type" => "draw", "count" => count}, socket) do
    n = String.to_integer(to_string(count))
    apply_action(socket, fn state, player ->
      with {:ok, new_state} <- Actions.draw(state, player, n) do
        {:ok, append_log(new_state, player, "drew #{n} card#{if n != 1, do: "s"}")}
      end
    end)
  end

  def handle_event("action", %{"type" => "draw"}, socket) do
    apply_action(socket, fn state, player ->
      with {:ok, new_state} <- Actions.draw(state, player, 1) do
        {:ok, append_log(new_state, player, "drew a card")}
      end
    end)
  end

  # ─── Life & Trackers ──────────────────────────────────────────────────────

  def handle_event("adjust_life", %{"delta" => delta}, socket) do
    delta = String.to_integer(delta)
    old_life = get_in(socket.assigns.game_state, [socket.assigns.my_role, "life"]) || 20
    socket = apply_action_inline(socket, fn state, player ->
      Actions.adjust_life(state, player, delta)
    end)
    socket = schedule_log(socket, "life", delta, fn total_delta, state, player ->
      new_life = get_in(state, [player, "life"])
      sign = if total_delta >= 0, do: "+", else: ""
      "life #{old_life} → #{new_life} (#{sign}#{total_delta})"
    end)
    {:noreply, socket}
  end

  def handle_event("add_tracker", %{"name" => name}, socket) do
    name = String.trim(name)

    if name != "" do
      apply_action(socket, fn state, player -> Actions.add_tracker(state, player, name) end)
    else
      {:noreply, socket}
    end
  end

  def handle_event("adjust_tracker", %{"index" => idx, "delta" => delta}, socket) do
    idx = String.to_integer(idx)
    delta = String.to_integer(delta)
    trackers = get_in(socket.assigns.game_state, [socket.assigns.my_role, "trackers"]) || []
    tracker = Enum.at(trackers, idx)
    tracker_name = tracker && tracker["name"] || "tracker"
    old_val = tracker && tracker["value"] || 0
    socket = apply_action_inline(socket, fn state, player ->
      Actions.adjust_tracker(state, player, idx, delta)
    end)
    socket = schedule_log(socket, "tracker-#{idx}", delta, fn total_delta, state, player ->
      new_val = get_in(state, [player, "trackers"]) |> Enum.at(idx) |> then(&(&1 && &1["value"] || 0))
      sign = if total_delta >= 0, do: "+", else: ""
      "#{tracker_name} #{old_val} → #{new_val} (#{sign}#{total_delta})"
    end)
    {:noreply, socket}
  end

  def handle_event("remove_tracker", %{"index" => idx}, socket) do
    idx = String.to_integer(idx)
    apply_action(socket, fn state, player -> Actions.remove_tracker(state, player, idx) end)
  end

  # ─── Counters ─────────────────────────────────────────────────────────────

  def handle_event("show_add_counter", %{"instance_id" => id}, socket) do
    {:noreply, assign(socket, adding_counter_to: id, counter_name_input: "", counter_has_quantity: true)}
  end

  def handle_event("add_counter", %{"name" => name} = params, socket) do
    id = socket.assigns.adding_counter_to
    name = String.trim(name)
    has_quantity = params["has_quantity"] == "true"

    if id do
      socket = apply_action_inline(socket, fn state, player ->
        Actions.add_counter(state, player, id, name, has_quantity)
      end)

      if name != "" do
        user = socket.assigns.current_scope.user
        updated_user = Accounts.add_recent_counter(user, name, has_quantity)
        updated_scope = %{socket.assigns.current_scope | user: updated_user}
        {:noreply, assign(socket, adding_counter_to: nil, recent_counters: updated_user.recent_counters, current_scope: updated_scope)}
      else
        {:noreply, assign(socket, adding_counter_to: nil)}
      end
    else
      {:noreply, assign(socket, adding_counter_to: nil)}
    end
  end

  def handle_event("add_recent_counter", %{"name" => name, "has_quantity" => hq}, socket) do
    id = socket.assigns.adding_counter_to
    has_quantity = hq == "true"

    socket = apply_action_inline(socket, fn state, player ->
      Actions.add_counter(state, player, id, name, has_quantity)
    end)

    user = socket.assigns.current_scope.user
    updated_user = Accounts.add_recent_counter(user, name, has_quantity)
    updated_scope = %{socket.assigns.current_scope | user: updated_user}

    {:noreply, assign(socket, adding_counter_to: nil, recent_counters: updated_user.recent_counters, current_scope: updated_scope)}
  end

  def handle_event("counter_form_change", params, socket) do
    name = params["name"] || ""
    has_quantity = params["has_quantity"] == "true"
    {:noreply, assign(socket, counter_name_input: name, counter_has_quantity: has_quantity)}
  end

  def handle_event("cancel_add_counter", _params, socket) do
    {:noreply, assign(socket, adding_counter_to: nil)}
  end

  def handle_event("adjust_counter", %{"instance_id" => id, "counter_index" => idx, "delta" => delta}, socket) do
    idx = String.to_integer(idx)
    delta = String.to_integer(delta)
    card_name = card_name_in_zone(socket, id)
    old_counter = find_card_in_zone(socket.assigns.game_state, socket.assigns.my_role, "battlefield", id)
      |> then(&(&1 && Enum.at(&1["counters"] || [], idx)))
    counter_name = old_counter && old_counter["name"] || "counter"
    old_val = old_counter && old_counter["value"] || 0
    socket = apply_action_inline(socket, fn state, player ->
      Actions.update_counter(state, player, id, idx, delta)
    end)
    socket = schedule_log(socket, "counter-#{id}-#{idx}", delta, fn total_delta, state, player ->
      new_val = find_card_in_zone(state, player, "battlefield", id)
        |> then(&(&1 && Enum.at(&1["counters"] || [], idx)))
        |> then(&(&1 && &1["value"] || 0))
      sign = if total_delta >= 0, do: "+", else: ""
      "#{card_name}: #{counter_name} #{old_val} → #{new_val} (#{sign}#{total_delta})"
    end)
    {:noreply, socket}
  end

  def handle_event("remove_counter", %{"instance_id" => id, "counter_index" => idx}, socket) do
    idx = String.to_integer(idx)
    apply_action(socket, fn state, player ->
      card = find_card_in_zone(state, player, "battlefield", id)
      counter_name = card && Enum.at(card["counters"] || [], idx) |> then(&(&1 && &1["name"])) || "counter"
      with {:ok, new_state} <- Actions.remove_counter(state, player, id, idx) do
        {:ok, append_log(new_state, player, "removed #{counter_name} from #{card_name_from_state(new_state, player, id)}")}
      end
    end)
  end

  # ─── Zone Popup ───────────────────────────────────────────────────────────

  def handle_event("set_viewed_opponent", %{"player_key" => key}, socket) do
    if key in socket.assigns.opponent_roles do
      {:noreply, assign(socket, viewed_opponent: key)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("open_zone", %{"zone" => zone, "owner" => owner}, socket) do
    {:noreply, assign(socket, open_zone: {owner, zone, %{}})}
  end

  def handle_event("close_zone", _params, socket) do
    {:noreply, assign(socket, open_zone: nil)}
  end

  # ─── Drag & Drop ──────────────────────────────────────────────────────────

  def handle_event("drag_end", params, socket) do
    instance_id = params["instance_id"]
    from_zone = params["from_zone"]
    target_zone = params["target_zone"]
    x = params["x"] || 0.1
    y = params["y"] || 0.5
    owner = params["owner"] || socket.assigns.my_role
    target_player = params["target_player"]
    selected_ids = params["selected_instance_ids"] || []

    # Only allow moving your own cards
    if owner != socket.assigns.my_role do
      {:noreply, socket}
    else
      insert_index = case params["insert_index"] do
        nil -> nil
        idx -> trunc(idx)
      end

      socket =
        case {from_zone, target_zone} do
          # Battlefield reposition (same zone)
          {"battlefield", "battlefield"} ->
            is_multi = length(selected_ids) > 1 and Enum.member?(selected_ids, instance_id)
            if is_multi do
              # Move all selected cards by the same delta as the dragged card
              apply_action_inline(socket, fn state, player ->
                bf_cards = get_in(state, [player, "zones", "battlefield"]) || []
                dragged = Enum.find(bf_cards, &(&1["instance_id"] == instance_id))
                dx = x - (dragged["x"] || 0.1)
                dy = y - (dragged["y"] || 0.5)
                Enum.reduce(selected_ids, {:ok, state}, fn sid, {:ok, st} ->
                  card = Enum.find(get_in(st, [player, "zones", "battlefield"]) || [], &(&1["instance_id"] == sid))
                  if card do
                    nx = max(0.0, min(0.98, (card["x"] || 0.1) + dx))
                    ny = max(0.0, min(0.98, (card["y"] || 0.5) + dy))
                    Actions.update_battlefield_position(st, player, sid, nx, ny, target_player)
                  else
                    {:ok, st}
                  end
                end)
                |> elem(1)
                |> then(&{:ok, &1})
              end)
            else
              apply_action_inline(socket, fn state, player ->
                Actions.update_battlefield_position(state, player, instance_id, x, y, target_player)
              end)
            end

          # Same list-zone reorder
          {zone, zone} when zone in ["hand", "deck", "graveyard", "exile"] ->
            apply_action_inline(socket, fn state, player ->
              Actions.reorder_in_zone(state, player, zone, instance_id, insert_index || 0)
            end)

          # Cross-zone moves to battlefield — use target_player to set on_battlefield
          {_, "battlefield"} ->
            all_ids = if length(selected_ids) > 1, do: selected_ids, else: [instance_id]
            apply_action_inline(socket, fn state, player ->
              {:ok, new_state} = Enum.reduce(all_ids, {:ok, state}, fn sid, {:ok, st} ->
                src = find_card_zone(st, player, sid) || from_zone
                Actions.move_to_player_battlefield(st, player, target_player || player, sid, src, x, y)
              end) |> elem(1) |> then(&{:ok, &1})
              names = Enum.map(all_ids, &card_name_from_state(new_state, player, &1))
              {:ok, append_log(new_state, player, "#{Enum.join(names, ", ")} → battlefield")}
            end)

          {_, "graveyard"} ->
            all_ids = if length(selected_ids) > 1, do: selected_ids, else: [instance_id]
            apply_action_inline(socket, fn state, player ->
              {:ok, new_state} = Enum.reduce(all_ids, {:ok, state}, fn sid, {:ok, st} ->
                src = find_card_zone(st, player, sid) || from_zone
                Actions.move_to_graveyard(st, player, sid, src)
              end) |> elem(1) |> then(&{:ok, &1})
              names = Enum.map(all_ids, &card_name_from_state(new_state, player, &1))
              {:ok, append_log(new_state, player, "#{Enum.join(names, ", ")} → graveyard")}
            end)

          {_, "exile"} ->
            all_ids = if length(selected_ids) > 1, do: selected_ids, else: [instance_id]
            apply_action_inline(socket, fn state, player ->
              {:ok, new_state} = Enum.reduce(all_ids, {:ok, state}, fn sid, {:ok, st} ->
                src = find_card_zone(st, player, sid) || from_zone
                Actions.move_to_exile(st, player, sid, src)
              end) |> elem(1) |> then(&{:ok, &1})
              names = Enum.map(all_ids, &card_name_from_state(new_state, player, &1))
              {:ok, append_log(new_state, player, "#{Enum.join(names, ", ")} → exile")}
            end)

          {_, "hand"} ->
            all_ids = if length(selected_ids) > 1, do: selected_ids, else: [instance_id]
            apply_action_inline(socket, fn state, player ->
              {:ok, new_state} = Enum.reduce(Enum.with_index(all_ids), {:ok, state}, fn {sid, i}, {:ok, st} ->
                src = find_card_zone(st, player, sid) || from_zone
                idx = if is_integer(insert_index), do: insert_index + i, else: nil
                Actions.move_to_hand(st, player, sid, src, idx)
              end) |> elem(1) |> then(&{:ok, &1})
              names = Enum.map(all_ids, &card_name_from_state(new_state, player, &1))
              {:ok, append_log(new_state, player, "#{Enum.join(names, ", ")} → hand")}
            end)

          {_, "deck"} ->
            all_ids = if length(selected_ids) > 1, do: selected_ids, else: [instance_id]
            apply_action_inline(socket, fn state, player ->
              {:ok, new_state} = Enum.reduce(Enum.with_index(all_ids), {:ok, state}, fn {sid, i}, {:ok, st} ->
                src = find_card_zone(st, player, sid) || from_zone
                idx = if is_integer(insert_index), do: insert_index + i, else: nil
                Actions.move_to_deck(st, player, sid, src, idx)
              end) |> elem(1) |> then(&{:ok, &1})
              names = Enum.map(all_ids, &card_name_from_state(new_state, player, &1))
              {:ok, append_log(new_state, player, "#{Enum.join(names, ", ")} → deck")}
            end)

          _ ->
            socket
        end

      # Keep the zone popup open when reordering within the same zone,
      # close it when a card is moved out.
      open_zone =
        case socket.assigns.open_zone do
          {owner, zone, opts} when zone == target_zone and owner == socket.assigns.my_role -> {owner, zone, opts}
          _ -> nil
        end

      {:noreply, assign(socket, open_zone: open_zone)}
    end
  end

  def handle_event("update_card_position", %{"instance_id" => id, "x" => x, "y" => y}, socket) do
    apply_action(socket, fn state, player ->
      Actions.update_battlefield_position(state, player, id, x, y)
    end)
  end

  # ─── Scry ─────────────────────────────────────────────────────────────────

  def handle_event("begin_scry", %{"count" => count_str}, socket) do
    count = min(String.to_integer(to_string(count_str)), 20)
    state = socket.assigns.game_state
    player = socket.assigns.my_role

    {top_cards, new_state} = Actions.scry_reveal(state, player, count)
    socket = persist_and_broadcast(socket, new_state)

    {:noreply,
     assign(socket,
       context_menu: nil,
       scry_session: %{cards: top_cards, count: count, decisions: %{}, decision_order: []}
     )}
  end

  def handle_event("scry_decision", %{"instance_id" => id, "dest" => dest}, socket) do
    scry = socket.assigns.scry_session
    new_decisions = Map.put(scry.decisions, id, dest)
    new_order = scry.decision_order ++ [id]
    scry = %{scry | decisions: new_decisions, decision_order: new_order}

    if map_size(new_decisions) == length(scry.cards) do
      # All decided, resolve — decision_order preserves click sequence
      state = socket.assigns.game_state
      player = socket.assigns.my_role
      new_state = Actions.scry_resolve(state, player, new_decisions, scry.cards, new_order)

      counts = Enum.frequencies(Map.values(new_decisions))
      top = Map.get(counts, "top", 0)
      bottom = Map.get(counts, "bottom", 0)
      parts = Enum.reject(["#{top} on top", "#{bottom} on bottom"], fn s -> String.starts_with?(s, "0") end)
      log_msg = "scryed #{length(scry.cards)}" <> if(parts == [], do: "", else: " (#{Enum.join(parts, ", ")})")

      # Log individual cards moved to graveyard/exile
      card_by_id = Map.new(scry.cards, &{&1["instance_id"], &1})
      logged_state =
        new_decisions
        |> Enum.filter(fn {_, dest} -> dest in ["graveyard", "exile"] end)
        |> Enum.reduce(new_state, fn {id, dest}, st ->
          name = get_in(card_by_id, [id, "name"]) || "card"
          append_log(st, player, "#{name} → #{dest}")
        end)
        |> append_log(player, log_msg)

      socket = persist_and_broadcast(socket, logged_state)
      {:noreply, assign(socket, scry_session: nil)}
    else
      {:noreply, assign(socket, scry_session: scry)}
    end
  end

  def handle_event("cancel_scry", _params, socket) do
    # Put cards back on top of deck
    scry = socket.assigns.scry_session
    state = socket.assigns.game_state
    player = socket.assigns.my_role

    if scry do
      # Return all cards to deck top (in original order)
      ids = Enum.map(scry.cards, & &1["instance_id"])
      decisions = Map.new(ids, &{&1, "top"})
      new_state = Actions.scry_resolve(state, player, decisions, scry.cards, ids)
      socket = persist_and_broadcast(socket, new_state)
      {:noreply, assign(socket, scry_session: nil)}
    else
      {:noreply, socket}
    end
  end

  # ─── Token Search ─────────────────────────────────────────────────────────

  def handle_event("show_token_search", %{"x" => x, "y" => y}, socket) do
    {:noreply, assign(socket, token_search: true, token_place_x: x, token_place_y: y)}
  end

  def handle_event("close_token_search", _params, socket) do
    {:noreply, assign(socket, token_search: nil)}
  end

  def handle_event("toggle_token_filter", _params, socket) do
    filter = if socket.assigns.token_filter == :tokens_only, do: :all, else: :tokens_only
    {:noreply, assign(socket, token_filter: filter)}
  end

  # ─── Find Card ────────────────────────────────────────────────────────────

  def handle_event("find_card_search", %{"query" => query}, socket) do
    case socket.assigns.open_zone do
      {owner, zone, opts} ->
        {:noreply, assign(socket, open_zone: {owner, zone, %{opts | query: query}})}
      _ ->
        {:noreply, socket}
    end
  end

  # ─── End Game ─────────────────────────────────────────────────────────────

  def handle_event("dismiss_die_roll", _params, socket) do
    state = socket.assigns.game_state
    player = socket.assigns.my_role
    dismissed = Map.get(state, "die_roll_dismissed", %{})
    new_state = Map.put(state, "die_roll_dismissed", Map.put(dismissed, player, true))
    {:ok, _} = Games.update_game_state(socket.assigns.game, new_state)
    {:noreply, assign(socket, die_roll_modal: false, game_state: new_state)}
  end

  def handle_event("show_end_game", _params, socket) do
    {:noreply, assign(socket, end_game_modal: true)}
  end

  def handle_event("cancel_end_game", _params, socket) do
    {:noreply, assign(socket, end_game_modal: false)}
  end

  def handle_event("confirm_end_game", _params, socket) do
    game = socket.assigns.game
    Games.broadcast_game_ended(game.id)
    Games.end_game(game)

    {:noreply,
     socket
     |> put_flash(:info, "Game ended.")
     |> push_navigate(to: ~p"/games")}
  end

  def handle_event("play_again_with_sideboard", _params, socket) do
    game = socket.assigns.game
    {:ok, updated_game} = Games.start_sideboarding(game)
    Games.broadcast_sideboarding_started(updated_game)

    sideboard_deck = build_sideboard_deck(updated_game.game_state, socket.assigns.my_role)

    {:noreply, assign(socket,
      game: updated_game,
      end_game_modal: false,
      sideboard_modal: true,
      sideboard_deck: sideboard_deck,
      sideboard_card_map: sideboard_card_map(sideboard_deck),
      sideboard_pending: []
    )}
  end

  def handle_event("reset_sideboard", _params, socket) do
    # Reset to original DB decklist
    deck_id = get_in(socket.assigns.game_state, [socket.assigns.my_role, "deck_id"])
    sideboard_deck = if deck_id, do: Decks.get_deck_with_cards!(deck_id), else: nil
    {:noreply, assign(socket, sideboard_deck: sideboard_deck, sideboard_card_map: sideboard_card_map(sideboard_deck))}
  end

  def handle_event("sideboard_move", %{"id" => id, "to_board" => to_board} = params, socket) do
    # Move N copies in memory only — never touch the DB.
    # count is provided by SideboardButton hook (batched clicks); defaults to 1.
    # IDs are compared as strings since they come from the template as strings
    # and synthetic entries may have non-integer ids like "new_123".
    count = String.to_integer(params["count"] || "1")
    deck = socket.assigns.sideboard_deck
    cards = deck.deck_cards

    source_card = Enum.find(cards, &(to_string(&1.id) == id))

    updated_cards =
      if source_card do
        move_qty = min(count, source_card.quantity)
        dest_card = Enum.find(cards, &(&1.oracle_id == source_card.oracle_id && &1.board == to_board))

        cards
        |> Enum.map(fn dc ->
          cond do
            to_string(dc.id) == id && dc.quantity > move_qty ->
              %{dc | quantity: dc.quantity - move_qty}
            to_string(dc.id) == id ->
              nil  # remove entirely
            dest_card && dc.id == dest_card.id ->
              %{dc | quantity: dc.quantity + move_qty}
            true ->
              dc
          end
        end)
        |> Enum.reject(&is_nil/1)
        |> then(fn cs ->
          if dest_card do
            cs
          else
            cs ++ [%{source_card | id: "new_#{source_card.id}", board: to_board, quantity: move_qty}]
          end
        end)
      else
        cards
      end

    {:noreply, assign(socket, sideboard_deck: %{deck | deck_cards: updated_cards})}
  end

  def handle_event("submit_sideboard", _params, socket) do
    game = socket.assigns.game
    my_role = socket.assigns.my_role
    deck = socket.assigns.sideboard_deck

    # Build card spec from in-memory deck (never touches DB)
    # Include printing_id so card art is preserved through sideboarding
    card_entries =
      deck.deck_cards
      |> Enum.filter(&(&1.board == "main"))
      |> Enum.flat_map(&List.duplicate({&1.oracle_id, &1.printing_id}, &1.quantity))

    commander_entries =
      deck.deck_cards
      |> Enum.filter(&(&1.board == "commander"))
      |> Enum.flat_map(&List.duplicate({&1.oracle_id, &1.printing_id}, &1.quantity))
    deck_id = deck.id

    card_spec = {card_entries, commander_entries, deck_id}

    {:ok, updated_game} = Games.submit_sideboard_with_card_list(game, my_role, card_spec)

    if Games.all_sideboard_ready?(updated_game) do
      # All ready — reinitialize game using stored card lists (no DB deck reads)
      state_data = updated_game.game_state
      card_lists = state_data["sideboard_card_lists"] || %{}

      card_specs =
        Map.new(updated_game.game_players, fn gp ->
          spec = card_lists[gp.player_key] || %{}
          # Convert [oracle_id, printing_id] lists back to {oracle_id, printing_id} tuples
          card_entries = Enum.map(spec["card_entries"] || [], fn [oid, p] -> {oid, p} end)
          commander_entries = Enum.map(spec["commander_entries"] || [], fn [oid, p] -> {oid, p} end)
          {gp.player_key, {card_entries, commander_entries, spec["deck_id"]}}
        end)

      players_with_keys = Enum.map(updated_game.game_players, &{&1.player_key, &1.user})

      new_state =
        State.initialize_with_card_lists(players_with_keys, card_specs, roll_die: false)
        |> Map.put("sideboard_card_lists", card_lists)

      {:ok, restarted} = Games.update_game_state(updated_game, new_state)
      {:ok, restarted} = Games.start_game(restarted)

      Games.broadcast_game_restarted(restarted)

      {:noreply, assign(socket,
        game: restarted,
        game_state: new_state,
        sideboard_modal: false,
        sideboard_pending: [],
        die_roll_modal: false
      )}
    else
      {:noreply, assign(socket, game: updated_game, sideboard_pending: [])}
    end
  end


  # ─── Private Helpers ─────────────────────────────────────────────────────

  # Build the starting deck for sideboarding.
  # Uses the card list from the previous sideboard (stored in game_state) if available,
  # so successive sideboards start from where the last one ended.
  # Falls back to the original DB deck on first sideboard.
  defp sideboard_card_img(card_map, oracle_id, printing_id \\ nil) do
    case Map.get(card_map, oracle_id) do
      nil -> nil
      card ->
        printing = if printing_id, do: Enum.find(card.printings || [], &(&1["id"] == printing_id))
        cond do
          printing -> get_in(printing, ["image_uris", "normal"])
          true ->
            get_in(card.data, ["image_uris", "normal"]) ||
              get_in(card.data, ["card_faces", Access.at(0), "image_uris", "normal"])
        end
    end
  end

  defp sideboard_card_map(nil), do: %{}
  defp sideboard_card_map(deck) do
    oracle_ids = Enum.map(deck.deck_cards, & &1.oracle_id) |> Enum.uniq()
    Catalog.list_cards_by_oracle_ids(oracle_ids) |> Map.new(&{&1.oracle_id, &1})
  end

  defp build_sideboard_deck(game_state, my_role) do
    card_lists = get_in(game_state, ["sideboard_card_lists", my_role])

    if card_lists do
      deck_id = card_lists["deck_id"]

      main_entries = Enum.map(card_lists["card_entries"] || [], fn [oid, p] -> {oid, p} end)
      commander_entries_raw = Enum.map(card_lists["commander_entries"] || [], fn [oid, p] -> {oid, p} end)

      # Build frequency map: oracle_id -> count
      main_counts =
        Enum.reduce(main_entries, %{}, fn {oracle_id, _pid}, acc ->
          Map.update(acc, oracle_id, 1, &(&1 + 1))
        end)

      # Build printing_id lookup from the stored entries (preserves selected art)
      stored_printing_ids =
        Enum.reduce(main_entries ++ commander_entries_raw, %{}, fn {oracle_id, pid}, acc ->
          Map.put_new(acc, oracle_id, pid)
        end)

      # Get original sideboard cards from DB to figure out what's "available" as sideboard
      original_deck = Decks.get_deck_with_cards!(deck_id)
      original_side =
        original_deck.deck_cards
        |> Enum.filter(&(&1.board == "sideboard"))
        |> Enum.reduce(%{}, fn dc, acc -> Map.put(acc, dc.oracle_id, dc.quantity) end)

      original_main =
        original_deck.deck_cards
        |> Enum.filter(&(&1.board == "main"))
        |> Enum.reduce(%{}, fn dc, acc -> Map.put(acc, dc.oracle_id, {dc.quantity, dc.printing_id}) end)

      # printing_id lookup: prefer stored (from previous sideboard), fall back to DB
      printing_ids =
        original_deck.deck_cards
        |> Enum.reduce(stored_printing_ids, fn dc, acc -> Map.put_new(acc, dc.oracle_id, dc.printing_id) end)

      # For each oracle_id that appears across main+side, compute current allocation
      all_oracle_ids =
        Map.keys(original_main) ++ Map.keys(original_side) |> Enum.uniq()

      deck_cards =
        all_oracle_ids
        |> Enum.flat_map(fn oracle_id ->
          {orig_main_qty, _} = Map.get(original_main, oracle_id, {0, nil})
          orig_side = Map.get(original_side, oracle_id, 0)
          total = orig_main_qty + orig_side
          cur_main = Map.get(main_counts, oracle_id, 0)
          cur_side = total - cur_main
          printing_id = Map.get(printing_ids, oracle_id)

          entries = []
          entries = if cur_main > 0, do: entries ++ [%{id: :erlang.phash2({oracle_id, "main"}), oracle_id: oracle_id, board: "main", quantity: cur_main, printing_id: printing_id}], else: entries
          entries = if cur_side > 0, do: entries ++ [%{id: :erlang.phash2({oracle_id, "sideboard"}), oracle_id: oracle_id, board: "sideboard", quantity: cur_side, printing_id: printing_id}], else: entries
          entries
        end)

      commander_deck_cards =
        commander_entries_raw
        |> Enum.frequencies_by(&elem(&1, 0))
        |> Enum.map(fn {oracle_id, qty} ->
          %{id: :erlang.phash2({oracle_id, "commander"}), oracle_id: oracle_id, board: "commander", quantity: qty, printing_id: Map.get(printing_ids, oracle_id)}
        end)

      %{id: deck_id, deck_cards: commander_deck_cards ++ deck_cards}
    else
      # First sideboard: load from DB
      deck_id = get_in(game_state, [my_role, "deck_id"])
      if deck_id, do: Decks.get_deck_with_cards!(deck_id), else: nil
    end
  end

  defp apply_action(socket, action_fn) do
    state = socket.assigns.game_state
    player = socket.assigns.my_role
    socket = assign(socket, context_menu: nil)

    case action_fn.(state, player) do
      {:ok, new_state} ->
        socket = persist_and_broadcast(socket, new_state)
        {:noreply, socket}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  defp apply_action_inline(socket, action_fn) do
    state = socket.assigns.game_state
    player = socket.assigns.my_role

    case action_fn.(state, player) do
      {:ok, new_state} ->
        persist_and_broadcast(socket, new_state)

      {:error, _reason} ->
        socket
    end
  end


  # Find which zone a card currently lives in (searches all zones for the player)
  defp find_card_zone(state, player, instance_id) do
    zones = ["hand", "battlefield", "graveyard", "exile", "deck"]
    Enum.find_value(zones, fn zone ->
      cards = get_in(state, [player, "zones", zone]) || []
      if Enum.any?(cards, &(&1["instance_id"] == instance_id)), do: zone
    end)
  end

  defp apply_to_selection(socket, action_fn, log_msg_fn) do
    ids = MapSet.to_list(socket.assigns.selected_cards)
    socket = assign(socket, context_menu: nil)
    state = socket.assigns.game_state
    player = socket.assigns.my_role

    new_state =
      Enum.reduce(ids, state, fn id, st ->
        case action_fn.(st, player, id) do
          {:ok, updated} -> updated
          {:error, _} -> st
        end
      end)

    new_state =
      case log_msg_fn do
        nil -> new_state
        f when is_function(f) -> append_log(new_state, player, f.(new_state, player))
        msg when is_binary(msg) -> append_log(new_state, player, msg)
      end

    socket = persist_and_broadcast(socket, new_state)
    {:noreply, socket}
  end

  defp persist_and_broadcast(socket, new_state) do
    game = socket.assigns.game
    {:ok, _} = Games.update_game_state(game, new_state)
    Games.broadcast_game_state(game.id, new_state)
    assign(socket, game_state: new_state)
  end

  # Schedule a debounced log entry for a counter-style event (life, tracker, card counter).
  # If the same key fires again within 1s, the timer resets and the delta accumulates.
  # The message_fn is only taken from the FIRST call in a burst — this preserves the
  # pre-burst "old value" captured by the caller before apply_action_inline runs.
  # After 1s of silence, :flush_log is sent and a single combined entry is written.
  defp schedule_log(socket, key, delta, message_fn) do
    pending = socket.assigns.pending_log
    entry = Map.get(pending, key, %{delta: 0, timer: nil, message_fn: message_fn})

    if entry.timer, do: Process.cancel_timer(entry.timer)
    timer = Process.send_after(self(), {:flush_log, key}, 1000)
    new_delta = entry.delta + delta

    assign(socket, pending_log: Map.put(pending, key, %{
      delta: new_delta,
      message_fn: entry.message_fn,  # keep the original message_fn (has the pre-burst old value)
      timer: timer
    }))
  end

  defp append_log(state, player, message) do
    username = get_in(state, [player, "username"]) || player
    entry = %{"t" => System.system_time(:second), "p" => player, "u" => username, "m" => message}
    existing = get_in(state, ["log"]) || []
    # Newest first, capped at 200 entries
    put_in(state, ["log"], Enum.take([entry | existing], 200))
  end

  # Find a card by instance_id in a specific zone of the current game state
  defp find_card_in_zone(state, player, zone, instance_id) do
    cards = get_in(state, [player, "zones", zone]) || []
    Enum.find(cards, &(&1["instance_id"] == instance_id))
  end

  # Look up a card name by instance_id. Only returns the real name if the card
  # is known to both players (i.e. public knowledge). Otherwise returns "a card".
  defp card_name_in_zone(socket, instance_id) do
    card_name_from_state(socket.assigns.game_state, socket.assigns.my_role, instance_id)
  end

  @move_actions [:move_to_graveyard, :move_to_exile, :move_to_deck_top, :move_to_deck_bottom, :move_to_hand]

  # Returns a JS command that optimistically hides the card element for zone-move actions.
  defp action_js(instance_id, zone, action) when action in @move_actions and not is_nil(instance_id) do
    el_id =
      case zone do
        "hand" -> "hand-card-#{instance_id}"
        _ -> "card-#{instance_id}"
      end
    JS.hide(to: "##{el_id}")
  end
  defp action_js(_instance_id, _zone, _action), do: %JS{}

  # For pile zones (graveyard, exile, deck), the client always sends the top card's
  # instance_id, but rapid keypresses will re-send the same id before the server has
  # responded. Resolve to the actual current top card so every event acts on a
  # different card regardless of what id arrived.
  defp resolve_pile_id(state, player, zone, client_id, popup_open \\ false)
  defp resolve_pile_id(_state, _player, _zone, client_id, true), do: client_id
  defp resolve_pile_id(state, player, zone, _client_id, false) when zone in ["graveyard", "exile", "deck"] do
    case get_in(state, [player, "zones", zone]) do
      [top | _] -> top["instance_id"]
      _ -> nil
    end
  end
  defp resolve_pile_id(_state, _player, _zone, client_id, _popup_open), do: client_id

  defp card_name_from_state(state, player, instance_id) do
    all_zones = ["battlefield", "graveyard", "exile", "hand", "deck"]
    card = Enum.find_value(all_zones, fn zone ->
      find_card_in_zone(state, player, zone, instance_id)
    end)
    if card && all_know?(state, card) do
      card["name"] || "a card"
    else
      "a card"
    end
  end

  # Returns true if every player in the game knows about this card.
  defp all_know?(state, card) do
    keys = State.all_player_keys(state)
    keys != [] && Enum.all?(keys, &State.known_to?(card, &1))
  end

  # ─── Template Helpers ─────────────────────────────────────────────────────

  defp my_state(game_state, my_role), do: game_state[my_role] || %{}
  defp opp_state(game_state, opp_role), do: game_state[opp_role] || %{}
  defp player_state(game_state, key), do: game_state[key] || %{}

  defp zone_cards(player_state, zone) do
    get_in(player_state, ["zones", zone]) || []
  end

  defp card_display_url(card, viewer_role, owner_role, zone) do
    State.card_display_url(card, viewer_role, owner_role, zone)
  end

  defp preview_attrs(url) do
    if url != State.card_back_url(), do: [{"data-card-img", url}], else: []
  end

  def render(assigns) do
    assigns =
      assigns
      |> assign(:my, my_state(assigns.game_state, assigns.my_role))
      |> assign(:opp, opp_state(assigns.game_state, assigns.viewed_opponent))
      |> assign(:battlefield_cards, State.battlefield_for_view(assigns.game_state, assigns.my_role, assigns.viewed_opponent))

    ~H"""
    <div class="h-full flex overflow-hidden bg-gray-950 select-none">
    <div
      id="game-container"
      class="game-layout flex-1 flex flex-col overflow-hidden min-w-0"
      phx-hook="DragDrop"
      data-my-role={@my_role}
    >
      <%!-- Opponent Selector (only shown when there are multiple opponents) --%>
      <%= if length(@opponent_roles) > 1 do %>
        <div class="flex items-center gap-2 px-4 py-1.5 bg-gray-950 border-b border-gray-700 shrink-0 overflow-x-auto">
          <%= for opp_key <- @opponent_roles do %>
            <% opp_data = player_state(@game_state, opp_key) %>
            <button
              phx-click="set_viewed_opponent"
              phx-value-player_key={opp_key}
              class={[
                "flex items-center gap-2 px-3 py-1 rounded-lg text-sm transition-colors shrink-0 border",
                if(@viewed_opponent == opp_key,
                  do: "bg-blue-700 text-white border-blue-500",
                  else: "bg-gray-800 text-gray-300 hover:bg-gray-700 border-gray-600"
                )
              ]}
            >
              <span class="font-medium">{opp_data["username"] || opp_key}</span>
              <span class="text-red-400 text-xs">♥ {opp_data["life"] || 20}</span>
              <%= for tracker <- opp_data["trackers"] || [] do %>
                <span class="text-xs text-gray-300 bg-gray-600/70 rounded px-1">{tracker["name"]} {tracker["value"]}</span>
              <% end %>
            </button>
          <% end %>
        </div>
      <% end %>

      <%!-- Opponent Info Bar --%>
      <div class="flex items-center gap-4 px-4 py-2 bg-gray-900 border-b border-gray-700 shrink-0">
        <span class="font-bold text-sm">{@opp["username"] || "Opponent"}</span>
        <div class="flex items-center gap-1 text-sm">
          <span class="text-red-400">♥</span>
          <span class="font-mono font-bold">{@opp["life"] || 20}</span>
        </div>
        <%= for {tracker, idx} <- Enum.with_index(@opp["trackers"] || []) do %>
          <div class="flex items-center gap-1 text-xs bg-gray-700 rounded px-2 py-1">
            <span>{tracker["name"]}</span>
            <span class="font-mono font-bold">{tracker["value"]}</span>
          </div>
        <% end %>
      </div>

      <%!-- Opponent Hand --%>
      <% opp_hand = zone_cards(@opp, "hand") %>
      <% hand_count = length(opp_hand) %>
      <div
        class="relative flex items-center bg-gray-900 border-b border-gray-700 overflow-x-auto shrink-0 cursor-pointer"
        style="height: 64px;"
        phx-click="open_zone"
        phx-value-zone="hand"
        phx-value-owner={@viewed_opponent}
      >
        <div class="flex items-center gap-1 px-4 py-2 min-w-max mx-auto">
          <%= if hand_count > 0 do %>
            <%= for card <- opp_hand do %>
              <% img_url = card_display_url(card, @my_role, @viewed_opponent, "hand") %>
              <img
                src={img_url}
                class="rounded shadow"
                style="width: 30px; height: 44px; object-fit: cover;"
                draggable="false"
                {preview_attrs(img_url)}
              />
            <% end %>
          <% else %>
            <span class="text-gray-500 text-sm">No cards in hand</span>
          <% end %>
        </div>
      </div>

      <%!-- Unified Battlefield — single coordinate space, both players' cards share this div --%>
      <div class="flex-1 min-h-0">
        <div
          id="battlefield"
          class="relative w-full h-full overflow-hidden"
          data-drop-zone="battlefield"
          data-my-role={@my_role}
          data-viewed-opponent={@viewed_opponent}
          data-move-keys={Hotkeys.move_keys_csv()}
          phx-hook="Battlefield"
          style="background: linear-gradient(to bottom, #111827 50%, #1a2332 50%);"
        >
          <%!-- Divider line between the two halves --%>
          <div class="absolute inset-x-0 pointer-events-none" style="top: 50%; height: 1px; background: #4b5563; z-index: 2;"></div>

          <%!-- Log toggle — left edge, vertically centered in my (bottom) half --%>
          <button
            phx-click="toggle_log"
            class={["absolute left-2 flex flex-col gap-1 p-1.5 rounded hover:bg-gray-700/60 transition-colors", if(@log_open, do: "text-blue-400", else: "text-gray-500 hover:text-gray-300")]}
            style="bottom: 140px; z-index: 30;"
            title="Game Log"
            data-no-hotkey
          >
            <span class="block w-4 h-0.5 bg-current rounded"></span>
            <span class="block w-4 h-0.5 bg-current rounded"></span>
            <span class="block w-4 h-0.5 bg-current rounded"></span>
          </button>

          <%!--
            All battlefield cards — rendered from a unified list of {card, owner_key} tuples.

            Orientation rule:
              - Upright if owner_key == my_role (draggable)
              - Flipped if owner_key != my_role AND effective_bf == owner_key
                  (opponent's own card on their own battlefield)
              - Upright, not interactable if owner_key != my_role AND effective_bf != owner_key
                  (opponent's card placed on a different player's battlefield)

            NOTE: .opp-card-inner must remain a direct child of .card-on-battlefield —
            the is-tapped CSS rule in app.css targets `.card-on-battlefield.is-tapped .opp-card-inner`.
          --%>
          <%= for {card, owner_key} <- @battlefield_cards do %>
            <% is_mine = owner_key == @my_role %>
            <% effective_bf = card["on_battlefield"] || owner_key %>
            <%# Flipped: opponent card on their own battlefield OR on my battlefield.
                Upright-not-interactable only when an opponent's card is on a third player's battlefield. %>
            <% flipped = not is_mine and (effective_bf == owner_key or effective_bf == @my_role) %>
            <% cx = Float.round((card["x"] || 0.5) * 100, 2) %>
            <% cy = Float.round((card["y"] || 0.5) * 100, 2) %>
            <%= if is_mine do %>
              <%!-- Upright + draggable: my own card --%>
              <div
                id={"card-#{card["instance_id"]}"}
                class={[
                  "card-on-battlefield absolute cursor-pointer transition-transform",
                  if(card["tapped"], do: "is-tapped", else: ""),
                  if(MapSet.member?(@selected_cards, card["instance_id"]), do: "is-selected", else: ""),
                ]}
                style={"left: #{cx}%; top: #{cy}%; z-index: #{card["z"] || 1};"}
                data-draggable="true"
                data-instance-id={card["instance_id"]}
                data-zone="battlefield"
                data-owner={@my_role}
                {preview_attrs(card_display_url(card, @my_role, @my_role, "battlefield"))}
                data-selected={if MapSet.member?(@selected_cards, card["instance_id"]), do: "true", else: "false"}
                data-is-token={if card["is_token"], do: "true", else: "false"}
              >
                <div class="card-draggable">
                  <img
                    src={card_display_url(card, @my_role, @my_role, "battlefield")}
                    class="card-image rounded shadow-lg"
                    draggable="false"
                  />
                </div>
                <%!-- Counters --%>
                <div :if={(card["counters"] || []) != []} class="absolute left-0 right-0 flex flex-col gap-0.5 items-center" style="top: 100%; margin-top: 2px;" data-no-hotkey>
                  <%= for {counter, cidx} <- Enum.with_index(card["counters"] || []) do %>
                    <div class="relative group/counter">
                      <div class="bg-gray-600/90 text-white rounded px-1.5 py-0.5 flex flex-col items-center leading-tight">
                        <%= if counter["has_quantity"] != false do %>
                          <div class="flex items-center gap-1 justify-center">
                            <button
                              phx-hook="CounterButton"
                              id={"counter-minus-#{card["instance_id"]}-#{cidx}"}
                              data-event="adjust_counter"
                              data-delta="-1"
                              data-params={Jason.encode!(%{"instance_id" => card["instance_id"], "counter_index" => to_string(cidx)})}
                              class="text-xs hover:text-red-300 shrink-0"
                            >-</button>
                            <span class="font-mono text-sm font-bold">{counter["value"]}</span>
                            <button
                              phx-hook="CounterButton"
                              id={"counter-plus-#{card["instance_id"]}-#{cidx}"}
                              data-event="adjust_counter"
                              data-delta="1"
                              data-params={Jason.encode!(%{"instance_id" => card["instance_id"], "counter_index" => to_string(cidx)})}
                              class="text-xs hover:text-green-300 shrink-0"
                            >+</button>
                          </div>
                        <% end %>
                        <span class="text-xs text-gray-300 text-center">{counter["name"]}</span>
                      </div>
                      <button
                        phx-click="remove_counter"
                        phx-value-instance_id={card["instance_id"]}
                        phx-value-counter_index={cidx}
                        class="absolute -right-4 top-1/2 -translate-y-1/2 hidden group-hover/counter:flex items-center justify-center bg-black text-white text-xs rounded-r w-4 h-full hover:text-red-400"
                      >×</button>
                    </div>
                  <% end %>
                </div>
              </div>
            <% else %>
            <%= if flipped do %>
              <%!-- Flipped: opponent's own card on their own battlefield (right/bottom, rotate 180°) --%>
              <div
                id={"opp-card-#{card["instance_id"]}"}
                class={["card-on-battlefield absolute cursor-pointer", if(card["tapped"], do: "is-tapped", else: "")]}
                style={"right: #{cx}%; bottom: #{cy}%; z-index: #{card["z"] || 1};"}
                data-hoverable="true"
                data-instance-id={card["instance_id"]}
                data-zone="battlefield"
                data-owner={owner_key}
              >
                <div class="opp-card-inner">
                  <div
                    style="transform: rotate(180deg); transform-origin: center;"
                    {preview_attrs(card_display_url(card, @my_role, owner_key, "battlefield"))}
                  >
                    <div class="flex flex-col items-center">
                      <img
                        src={card_display_url(card, @my_role, owner_key, "battlefield")}
                        class="card-image rounded shadow-lg"
                        draggable="false"
                      />
                      <%= if (card["counters"] || []) != [] do %>
                        <div class="flex flex-col gap-0.5 mt-0.5 items-center">
                          <%= for counter <- card["counters"] || [] do %>
                            <div class="bg-gray-600/90 text-white rounded px-1.5 py-0.5 flex flex-col items-center leading-tight w-full">
                              <%= if counter["has_quantity"] != false do %>
                                <span class="font-mono text-sm font-bold">{counter["value"]}</span>
                              <% end %>
                              <span class="text-xs text-gray-300 text-center">{counter["name"]}</span>
                            </div>
                          <% end %>
                        </div>
                      <% end %>
                    </div>
                  </div>
                </div>
              </div>
            <% else %>
              <%!-- Upright, not interactable: opponent's card on a third player's battlefield --%>
              <div
                id={"opp-card-#{card["instance_id"]}"}
                class={["card-on-battlefield absolute cursor-default", if(card["tapped"], do: "is-tapped", else: "")]}
                style={"left: #{cx}%; top: #{cy}%; z-index: #{card["z"] || 1};"}
                data-instance-id={card["instance_id"]}
                data-zone="battlefield"
                data-owner={owner_key}
              >
                <div>
                  <img
                    src={card_display_url(card, @my_role, owner_key, "battlefield")}
                    class="card-image rounded shadow-lg"
                    draggable="false"
                  />
                </div>
                <%= if (card["counters"] || []) != [] do %>
                  <div class="flex flex-col gap-0.5 mt-0.5 items-center">
                    <%= for counter <- card["counters"] || [] do %>
                      <div class="bg-gray-600/90 text-white rounded px-1.5 py-0.5 flex flex-col items-center leading-tight w-full">
                        <span class="font-mono text-sm font-bold">{counter["value"]}</span>
                        <span class="text-xs text-gray-300 text-center">{counter["name"]}</span>
                      </div>
                    <% end %>
                  </div>
                <% end %>
              </div>
            <% end %>
            <% end %>
          <% end %>

          <%!-- Opponent zone piles — mirrored from their layout (their bottom-right = our top-left, etc.) --%>
          <%!-- Opponent Deck — their bottom-right → our top-left --%>
          <div
            class="absolute cursor-pointer"
            style="top: 8px; left: 8px; z-index: 20;"
            phx-click="open_zone"
            phx-value-zone="deck"
            phx-value-owner={@viewed_opponent}
          >
            <div class="relative" style="width: 56px; height: 78px;">
              <%= if zone_cards(@opp, "deck") != [] do %>
                <img src={card_display_url(hd(zone_cards(@opp, "deck")), @my_role, @viewed_opponent, "deck")} class="rounded shadow-lg pointer-events-none" style="width: 56px; height: 78px; object-fit: cover;" draggable="false" />
              <% else %>
                <div class="w-full h-full bg-gray-800 border border-gray-600 rounded flex flex-col items-center justify-center gap-0.5">
                  <span class="text-gray-400 text-xs font-semibold">DECK</span>
                </div>
              <% end %>
              <div class="absolute bottom-0 right-0 bg-black/70 text-white text-xs px-1 rounded-tl leading-4 pointer-events-none">
                {length(zone_cards(@opp, "deck"))}
              </div>
            </div>
          </div>

          <%!-- Opponent Graveyard — their bottom-left → our top-right --%>
          <div
            class="absolute cursor-pointer"
            style="top: 8px; right: 8px; z-index: 20;"
            phx-click="open_zone"
            phx-value-zone="graveyard"
            phx-value-owner={@viewed_opponent}
          >
            <div class="relative" style="width: 78px; height: 56px;">
              <%= if zone_cards(@opp, "graveyard") != [] do %>
                <img
                  src={card_display_url(hd(zone_cards(@opp, "graveyard")), @viewed_opponent, @viewed_opponent, "graveyard")}
                  class="rounded pointer-events-none"
                  style="position: absolute; top: 50%; left: 50%; width: 56px; height: 78px; object-fit: cover; transform: translate(-50%, -50%) rotate(90deg);"
                  draggable="false"
                />
              <% else %>
                <div class="w-full h-full bg-gray-800 border border-gray-600 rounded flex flex-col items-center justify-center gap-0.5">
                  <span class="text-gray-400 text-xs font-semibold">GY</span>
                </div>
              <% end %>
              <div class="absolute bottom-0 right-0 bg-black/70 text-white text-xs px-1 rounded-tl leading-4 pointer-events-none">
                {length(zone_cards(@opp, "graveyard"))}
              </div>
            </div>
          </div>

          <%!-- Opponent Exile — their above-graveyard-bottom-left → our below-graveyard-top-right --%>
          <div
            class="absolute cursor-pointer"
            style="top: 72px; right: 8px; z-index: 20;"
            phx-click="open_zone"
            phx-value-zone="exile"
            phx-value-owner={@viewed_opponent}
          >
            <div class="relative" style="width: 78px; height: 56px;">
              <%= if zone_cards(@opp, "exile") != [] do %>
                <img
                  src={card_display_url(hd(zone_cards(@opp, "exile")), @viewed_opponent, @viewed_opponent, "exile")}
                  class="rounded pointer-events-none"
                  style="position: absolute; top: 50%; left: 50%; width: 56px; height: 78px; object-fit: cover; transform: translate(-50%, -50%) rotate(90deg);"
                  draggable="false"
                />
              <% else %>
                <div class="w-full h-full bg-gray-800 border border-gray-600 rounded flex flex-col items-center justify-center gap-0.5 cursor-pointer">
                  <span class="text-gray-400 text-xs font-semibold">EX</span>
                </div>
              <% end %>
              <div class="absolute bottom-0 right-0 bg-black/70 text-white text-xs px-1 rounded-tl leading-4 pointer-events-none">
                {length(zone_cards(@opp, "exile"))}
              </div>
            </div>
          </div>

          <%!-- Zone Piles (sideways / landscape orientation to distinguish from battlefield cards) --%>
          <%!-- Graveyard pile: bottom-left (sideways / landscape) --%>
          <div
            id="pile-graveyard"
            class="zone-pile absolute rounded shadow-lg overflow-hidden"
            style="width: 78px; height: 56px; bottom: 8px; left: 8px; z-index: 20;"
            data-drop-zone="graveyard"
            data-pile-zone="graveyard"
            phx-click="open_zone"
            phx-value-zone="graveyard"
            phx-value-owner={@my_role}
          >
            <%= if zone_cards(@my, "graveyard") != [] do %>
              <%!-- Persistent background card image (always visible, even during drag) --%>
              <img
                src={card_display_url(hd(zone_cards(@my, "graveyard")), @my_role, @my_role, "graveyard")}
                class="rounded pointer-events-none"
                style="position: absolute; top: 50%; left: 50%; width: 56px; height: 78px; object-fit: cover; transform: translate(-50%, -50%) rotate(90deg);"
                draggable="false"
              />
              <%!-- Transparent draggable overlay for the top card --%>
              <div
                id={"graveyard-top-#{hd(zone_cards(@my, "graveyard"))["instance_id"]}"}
                class="absolute inset-0 cursor-pointer"
                data-draggable="true"
                data-instance-id={hd(zone_cards(@my, "graveyard"))["instance_id"]}
                data-zone="graveyard"
                data-owner={@my_role}
                data-card-img={card_display_url(hd(zone_cards(@my, "graveyard")), @my_role, @my_role, "graveyard")}
              ></div>
            <% else %>
              <div class="w-full h-full bg-gray-800 border border-gray-600 rounded flex flex-col items-center justify-center gap-0.5 cursor-pointer">
                <span class="text-gray-400 text-xs font-semibold">GY</span>
              </div>
            <% end %>
            <div class="absolute bottom-0 right-0 bg-black/70 text-white text-xs px-1 rounded-tl leading-4 pointer-events-none">
              {length(zone_cards(@my, "graveyard"))}
            </div>
          </div>

          <%!-- Exile pile: above graveyard on left (sideways / landscape) --%>
          <div
            id="pile-exile"
            class="zone-pile absolute rounded shadow-lg overflow-hidden"
            style="width: 78px; height: 56px; bottom: 72px; left: 8px; z-index: 20;"
            data-drop-zone="exile"
            data-pile-zone="exile"
            phx-click="open_zone"
            phx-value-zone="exile"
            phx-value-owner={@my_role}
          >
            <%= if zone_cards(@my, "exile") != [] do %>
              <%!-- Persistent background card image (always visible, even during drag) --%>
              <img
                src={card_display_url(hd(zone_cards(@my, "exile")), @my_role, @my_role, "exile")}
                class="rounded pointer-events-none"
                style="position: absolute; top: 50%; left: 50%; width: 56px; height: 78px; object-fit: cover; transform: translate(-50%, -50%) rotate(90deg);"
                draggable="false"
              />
              <%!-- Transparent draggable overlay for the top card --%>
              <div
                id={"exile-top-#{hd(zone_cards(@my, "exile"))["instance_id"]}"}
                class="absolute inset-0 cursor-pointer"
                data-draggable="true"
                data-instance-id={hd(zone_cards(@my, "exile"))["instance_id"]}
                data-zone="exile"
                data-owner={@my_role}
                data-card-img={card_display_url(hd(zone_cards(@my, "exile")), @my_role, @my_role, "exile")}
              ></div>
            <% else %>
              <div class="w-full h-full bg-gray-800 border border-gray-600 rounded flex flex-col items-center justify-center gap-0.5 cursor-pointer">
                <span class="text-gray-400 text-xs font-semibold">EX</span>
              </div>
            <% end %>
            <div class="absolute bottom-0 right-0 bg-black/70 text-white text-xs px-1 rounded-tl leading-4 pointer-events-none">
              {length(zone_cards(@my, "exile"))}
            </div>
          </div>

          <%!-- Deck pile: bottom-right (upright, top card draggable) --%>
          <div
            id="pile-deck"
            class="zone-pile absolute rounded shadow-lg overflow-hidden"
            style="width: 56px; height: 78px; bottom: 8px; right: 8px; z-index: 20;"
            data-drop-zone="deck"
            data-pile-zone="deck"
            data-no-preview
            phx-click="open_zone"
            phx-value-zone="deck"
            phx-value-owner={@my_role}
          >
            <%= if zone_cards(@my, "deck") != [] do %>
              <%!-- Persistent background image (always visible, even during drag) --%>
              <img
                src={card_display_url(hd(zone_cards(@my, "deck")), @my_role, @my_role, "deck")}
                class="absolute inset-0 w-full h-full object-cover rounded pointer-events-none"
                draggable="false"
              />
              <%!-- Transparent draggable overlay for the top card --%>
              <div
                id={"deck-top-#{hd(zone_cards(@my, "deck"))["instance_id"]}"}
                class="absolute inset-0 cursor-pointer"
                data-draggable="true"
                data-instance-id={hd(zone_cards(@my, "deck"))["instance_id"]}
                data-zone="deck"
                data-owner={@my_role}
                {preview_attrs(card_display_url(hd(zone_cards(@my, "deck")), @my_role, @my_role, "deck"))}
              ></div>
              <div class="absolute bottom-0 right-0 bg-black/70 text-white text-xs px-1 rounded-tl leading-4 pointer-events-none" style="z-index: 1;">
                {length(zone_cards(@my, "deck"))}
              </div>
            <% else %>
              <div class="w-full h-full bg-gray-800 border border-gray-600 rounded flex flex-col items-center justify-center gap-0.5">
                <span class="text-gray-400 text-xs font-semibold">DECK</span>
              </div>
            <% end %>
          </div>

          <%!-- Right-click context placeholder (handled via JS) --%>
          <div
            :if={@context_menu}
            id="context-menu"
            class="fixed z-50 bg-gray-800 border border-gray-600 rounded-lg shadow-xl py-1 min-w-48"
            style={"left: min(#{@context_menu.x}px, calc(100vw - 200px)); bottom: min(#{@context_menu.y_from_bottom}px, calc(100vh - 8px));"}
          >
            <%= for action <- @context_menu.actions do %>
              <%= if action == :toggle_top_revealed do %>
                <button
                  class="w-full text-left px-4 py-2 text-sm hover:bg-gray-700 flex items-center justify-between"
                  phx-click="action"
                  phx-value-type="toggle_top_revealed"
                  phx-value-instance_id={@context_menu.instance_id}
                  phx-value-zone={@context_menu.zone}
                >
                  <span class="flex items-center gap-2">
                    <span :if={@context_menu.top_revealed} class="text-green-400 text-xs">●</span>
                    <span :if={!@context_menu.top_revealed} class="text-gray-500 text-xs">○</span>
                    {if @context_menu.top_revealed, do: "Stop Revealing Top", else: "Keep Top Revealed"}
                  </span>
                </button>
              <% else %>
              <%= if action == :draw_top_to do %>
                <%!-- Submenu row: hover opens destination picker --%>
                <div class="relative" id="draw-to-row">
                  <div class="flex items-center justify-between px-4 py-2 text-sm text-gray-200 hover:bg-gray-700 cursor-default select-none">
                    <span>Draw To</span>
                    <span class="text-gray-400 ml-6">›</span>
                  </div>
                  <div id="draw-to-submenu" class="submenu-panel absolute left-full top-0 bg-gray-800 border border-gray-600 rounded-lg shadow-xl py-1 min-w-44 z-10" style="display:none">
                    <%= for {label, dest, hint} <- [
                      {"Battlefield", "battlefield", Hotkeys.display_for(:move_to_battlefield)},
                      {"Battlefield (Face Down)", "battlefield_face_down", Hotkeys.display_for(:draw_face_down)},
                      {"Graveyard", "graveyard", Hotkeys.display_for(:move_to_graveyard)},
                      {"Exile", "exile", Hotkeys.display_for(:move_to_exile)},
                      {"Hand", "hand", Hotkeys.display_for(:move_to_hand)}
                    ] do %>
                      <button
                        phx-click={JS.push("action", value: %{type: "draw_top_to", dest: dest})}
                        class="w-full text-left px-4 py-2 text-sm hover:bg-gray-700 flex items-center justify-between gap-4"
                      >
                        <span>{label}</span>
                        <span :if={hint} class="text-gray-500 text-xs font-mono">{hint}</span>
                      </button>
                    <% end %>
                  </div>
                </div>
              <% else %>
              <%= if action == :scry do %>
                <%!-- Scry row: label + count adjuster + confirm --%>
                <div class="flex items-center px-4 py-2 text-sm gap-2">
                  <span class="flex-1">Scry</span>
                  <button
                    phx-click="adjust_scry_count"
                    phx-value-delta="-1"
                    class="text-gray-400 hover:text-white w-5 text-center"
                  >−</button>
                  <span class="font-mono w-4 text-center">{@context_menu.scry_count}</span>
                  <button
                    phx-click="adjust_scry_count"
                    phx-value-delta="1"
                    class="text-gray-400 hover:text-white w-5 text-center"
                  >+</button>
                  <button
                    phx-click="begin_scry"
                    phx-value-count={@context_menu.scry_count}
                    class="btn btn-xs btn-outline ml-1"
                  >Go</button>
                </div>
              <% else %>
                <button
                  class="w-full text-left px-4 py-2 text-sm hover:bg-gray-700 flex items-center justify-between"
                  phx-click={
                    action_js(@context_menu.instance_id, @context_menu.zone, action)
                    |> JS.push("action", value: %{type: action, instance_id: @context_menu.instance_id, zone: @context_menu.zone})
                  }
                >
                  <span>{Hotkeys.action_label(action)}</span>
                  <span :if={Hotkeys.key_for(action)} class="text-xs text-gray-400 ml-4">
                    {Hotkeys.display_for(action)}
                  </span>
                </button>
              <% end %>
              <% end %>
              <% end %>
            <% end %>
          </div>
        </div>
      </div>

      <%!-- My Info Bar --%>
      <div class="flex items-center gap-4 px-4 py-2 bg-gray-900 border-t border-gray-700 shrink-0">
          <%!-- Life Total --%>
          <div class="flex items-center gap-1">
            <span class="text-red-400 font-bold">♥</span>
            <button
              phx-hook="CounterButton"
              id="life-minus"
              data-event="adjust_life"
              data-delta="-1"
              class="btn btn-xs btn-ghost text-red-400"
            >-</button>
            <span class="font-mono font-bold text-lg w-8 text-center">{@my["life"] || 20}</span>
            <button
              phx-hook="CounterButton"
              id="life-plus"
              data-event="adjust_life"
              data-delta="1"
              class="btn btn-xs btn-ghost text-green-400"
            >+</button>
          </div>

          <%!-- Trackers --%>
          <%= for {tracker, idx} <- Enum.with_index(@my["trackers"] || []) do %>
            <div class="relative group/tracker">
              <div class="flex items-center gap-1 text-xs bg-gray-700 rounded px-2 py-1">
                <span>{tracker["name"]}</span>
                <button
                  phx-hook="CounterButton"
                  id={"tracker-minus-#{idx}"}
                  data-event="adjust_tracker"
                  data-delta="-1"
                  data-params={Jason.encode!(%{"index" => to_string(idx)})}
                  class="hover:text-red-400"
                >-</button>
                <span class="font-mono font-bold">{tracker["value"]}</span>
                <button
                  phx-hook="CounterButton"
                  id={"tracker-plus-#{idx}"}
                  data-event="adjust_tracker"
                  data-delta="1"
                  data-params={Jason.encode!(%{"index" => to_string(idx)})}
                  class="hover:text-green-400"
                >+</button>
              </div>
              <button
                phx-click="remove_tracker"
                phx-value-index={idx}
                class="absolute -right-4 top-0 hidden group-hover/tracker:flex items-center justify-center bg-black text-white text-xs rounded-r w-4 h-full hover:text-red-400"
              >×</button>
            </div>
          <% end %>

          <form phx-submit="add_tracker" class="flex gap-1">
            <input
              type="text"
              name="name"
              placeholder="+ Tracker"
              class="input input-xs bg-gray-700 w-24 placeholder-gray-500"
            />
          </form>

          <div class="ml-auto flex items-center gap-2 text-xs text-gray-400">
            <span>Hand: {length(zone_cards(@my, "hand"))}</span>
            <button phx-click="show_end_game" class="text-red-400 hover:text-red-300">
              End Game
            </button>
          </div>
        </div>

        <%!-- Hand --%>
        <div
          id="my-hand"
          data-drop-zone="hand"
          class="relative flex items-center bg-gray-900 border-t border-gray-700 overflow-x-auto shrink-0"
          style="height: 120px;"
        >
          <div class="flex items-center gap-1 px-4 py-2 min-w-max mx-auto">
            <%= for card <- zone_cards(@my, "hand") do %>
              <div
                id={"hand-card-#{card["instance_id"]}"}
                class={[
                  "shrink-0 cursor-pointer hover:scale-110 transition-transform relative",
                  ]}
                data-draggable="true"
                data-instance-id={card["instance_id"]}
                data-zone="hand"
                data-owner={@my_role}
                data-card-img={card_display_url(card, @my_role, @my_role, "hand")}
                data-is-token={if card["is_token"], do: "true", else: "false"}
              >
                <img
                  src={card_display_url(card, @my_role, @my_role, "hand")}
                  class="h-24 w-auto rounded shadow"
                  draggable="false"
                />
              </div>
            <% end %>
          </div>

          <%!-- Hand menu button (top-right corner) --%>
          <button
            id="hand-menu-btn"
            class="absolute top-2 right-2 p-1.5 rounded text-gray-400 hover:text-white hover:bg-gray-700 transition-colors"
            title="Hand options"
          >
            <svg xmlns="http://www.w3.org/2000/svg" class="h-4 w-4" fill="none" viewBox="0 0 24 24" stroke="currentColor">
              <path stroke-linecap="round" stroke-linejoin="round" stroke-width="2" d="M4 6h16M4 12h16M4 18h16" />
            </svg>
          </button>
        </div>

        <%!-- Zone Popup (inline, below hand) --%>
        <div
          :if={@open_zone}
          class="bg-gray-900 border-t border-gray-600 shrink-0"
          style="height: 180px;"
        >
          <% {zone_owner, zone_name, zone_opts} = @open_zone %>
          <% zone_player = if zone_owner == @my_role, do: @my, else: @opp %>
          <% is_find = Map.get(zone_opts, :find, false) %>
          <div class="flex items-center justify-between px-4 py-1 border-b border-gray-700">
            <div class="flex items-center gap-3">
              <span class="font-semibold text-sm">
                {if is_find, do: "Find Card", else: String.capitalize(zone_name)} ({length(zone_cards(zone_player, zone_name))} cards)
              </span>
              <form :if={is_find} phx-change="find_card_search">
                <input
                  type="text"
                  name="query"
                  value={Map.get(zone_opts, :query, "")}
                  phx-debounce="100"
                  placeholder="Filter by name..."
                  class="input input-xs bg-gray-700 w-40 placeholder-gray-500"
                  autofocus
                />
              </form>
            </div>
            <button phx-click="close_zone" class="text-gray-400 hover:text-white text-xl leading-none">×</button>
          </div>
          <div
            class="flex overflow-x-auto"
            style="height: 148px;"
            data-drop-zone={zone_name}
          >
            <div class="flex items-center gap-2 px-4 py-2 min-w-max mx-auto">
              <%
                cards = zone_cards(zone_player, zone_name)
                cards = if is_find do
                  query = String.downcase(Map.get(zone_opts, :query, ""))
                  cards
                  |> Enum.sort_by(& &1["name"])
                  |> Enum.filter(fn c -> query == "" or String.contains?(String.downcase(c["name"]), query) end)
                else
                  cards
                end
              %>
              <%= for card <- cards do %>
                <% display_card = if is_find, do: put_in(card, ["known", @my_role], true), else: card %>
                <% img_url = card_display_url(display_card, @my_role, zone_owner, zone_name) %>
                <div
                  id={"zone-card-#{card["instance_id"]}"}
                  class="shrink-0 cursor-pointer hover:scale-105 transition-transform"
                  data-draggable="true"
                  data-instance-id={card["instance_id"]}
                  data-zone={zone_name}
                  data-owner={zone_owner}
                  {preview_attrs(img_url)}
                >
                  <img
                    src={card_display_url(display_card, @my_role, zone_owner, zone_name)}
                    class="h-32 w-auto rounded shadow"
                    draggable="false"
                  />
                </div>
              <% end %>
            </div>
          </div>
        </div>

      <%!-- Card Preview Panel (shown on hover via JS, hidden during drag) --%>
      <div
        id="card-preview-panel"
        phx-update="ignore"
        class="fixed top-1/2 -translate-y-1/2 z-[9999] pointer-events-none"
        style="display: none; right: 12px;"
      >
        <img
          id="card-preview-img"
          src=""
          class="rounded-lg shadow-2xl"
          style="height: 420px; width: auto;"
          draggable="false"
        />
      </div>
    </div>

    <%!-- Game Log Sidebar --%>
    <div
      :if={@log_open}
      class="w-64 flex flex-col bg-gray-900 border-l border-gray-700 shrink-0 overflow-hidden"
    >
      <div class="flex items-center justify-between px-3 py-2 border-b border-gray-700 shrink-0">
        <span class="text-sm font-semibold">Game Log</span>
        <button phx-click="toggle_log" class="text-gray-400 hover:text-white text-lg leading-none">×</button>
      </div>
      <div id="game-log-scroll" phx-hook="ScrollBottom" class="flex-1 overflow-y-auto px-3 py-2 flex flex-col gap-1">
        <div :if={(get_in(@game_state, ["log"]) || []) == []} class="text-xs text-gray-500 italic">
          No actions yet.
        </div>
        <%= for entry <- Enum.reverse(get_in(@game_state, ["log"]) || []) do %>
          <div class="text-xs leading-relaxed">
            <span class={if entry["p"] == @my_role, do: "text-blue-400 font-medium", else: "text-orange-400 font-medium"}>
              {entry["u"]}
            </span>
            <span class="text-gray-300"> {entry["m"]}</span>
          </div>
        <% end %>
      </div>
    </div>

      <%!-- Scry Modal --%>
      <div
        :if={@scry_session}
        class="fixed inset-0 bg-black/80 flex items-center justify-center z-50"
      >
        <div class="bg-gray-800 rounded-xl p-6 max-w-4xl w-full mx-4">
          <div class="flex items-center justify-between mb-4">
            <h2 class="text-xl font-bold">
              Scrying {length(@scry_session.cards)} card(s)
            </h2>
            <button phx-click="cancel_scry" class="text-gray-400 hover:text-white">Cancel</button>
          </div>

          <div class="flex gap-3 overflow-x-auto pb-2">
            <%= for card <- @scry_session.cards do %>
              <div class="shrink-0 text-center">
                <img
                  src={card_display_url(card, @my_role, @my_role, "deck")}
                  class="h-40 w-auto rounded shadow mx-auto mb-2"
                />
                <div class="text-xs text-gray-300 mb-2 max-w-24 truncate">{card["name"]}</div>
                <div :if={!Map.has_key?(@scry_session.decisions, card["instance_id"])} class="flex flex-col gap-1">
                  <button
                    phx-click="scry_decision"
                    phx-value-instance_id={card["instance_id"]}
                    phx-value-dest="top"
                    class="btn btn-xs btn-outline"
                  >
                    Top
                  </button>
                  <button
                    phx-click="scry_decision"
                    phx-value-instance_id={card["instance_id"]}
                    phx-value-dest="bottom"
                    class="btn btn-xs btn-ghost"
                  >
                    Bottom
                  </button>
                  <button
                    phx-click="scry_decision"
                    phx-value-instance_id={card["instance_id"]}
                    phx-value-dest="graveyard"
                    class="btn btn-xs btn-ghost text-red-400"
                  >
                    Grave
                  </button>
                  <button
                    phx-click="scry_decision"
                    phx-value-instance_id={card["instance_id"]}
                    phx-value-dest="exile"
                    class="btn btn-xs btn-ghost text-yellow-400"
                  >
                    Exile
                  </button>
                </div>
                <div :if={Map.has_key?(@scry_session.decisions, card["instance_id"])} class="text-xs text-green-400 capitalize">
                  → {Map.get(@scry_session.decisions, card["instance_id"])}
                </div>
              </div>
            <% end %>
          </div>
        </div>
      </div>

      <%!-- Token Search Modal --%>
      <div
        :if={@token_search}
        class="fixed inset-0 bg-black/80 flex items-center justify-center z-50"
      >
        <div class="bg-gray-800 rounded-xl p-6 w-full max-w-lg mx-4">
          <div class="flex items-center justify-between mb-4">
            <h2 class="text-xl font-bold">Create Token / Spawn Card</h2>
            <div class="flex items-center gap-4">
              <label class="flex items-center gap-2 text-sm text-gray-300 cursor-pointer select-none">
                <input
                  type="checkbox"
                  checked={@token_filter == :tokens_only}
                  phx-click="toggle_token_filter"
                  class="checkbox checkbox-sm checkbox-primary"
                />
                Tokens only
              </label>
              <button phx-click="close_token_search" class="text-gray-400 hover:text-white text-2xl leading-none">&times;</button>
            </div>
          </div>
          <.live_component
            module={GoodtapWeb.CardSearchComponent}
            id="token-search"
            filter={@token_filter}
            show_filter_toggle={false}
            on_select={:token_selected}
            recent_card_names={@recent_tokens}
          />
        </div>
      </div>

      <%!-- Add Counter Modal --%>
      <div
        :if={@adding_counter_to}
        class="fixed inset-0 bg-black/70 flex items-center justify-center z-50"
      >
        <div class="bg-gray-800 rounded-xl p-6 w-80 mx-4">
          <h2 class="text-lg font-bold mb-4">Add Counter</h2>
          <%= if @recent_counters != [] do %>
            <p class="text-xs text-gray-500 mb-1.5">Recent</p>
            <div class="flex flex-wrap gap-2 mb-3 pb-2 border-b border-gray-700">
              <%= for rc <- @recent_counters do %>
                <button
                  type="button"
                  phx-click="add_recent_counter"
                  phx-value-name={rc["name"]}
                  phx-value-has_quantity={to_string(rc["has_quantity"])}
                  class="px-2 py-0.5 bg-gray-700 hover:bg-gray-600 rounded text-xs text-gray-200 border border-gray-600 cursor-pointer"
                >
                  {rc["name"]}<%= if rc["has_quantity"] do %> <span class="text-gray-400">#</span><% end %>
                </button>
              <% end %>
            </div>
          <% end %>
          <% counter_valid = String.trim(@counter_name_input) != "" or @counter_has_quantity %>
          <form phx-submit="add_counter" phx-change="counter_form_change">
            <input
              type="text"
              name="name"
              value={@counter_name_input}
              placeholder="Add Label (Optional)"
              class="input input-bordered w-full bg-gray-700 mb-3"
              autofocus
            />
            <label class="flex items-center gap-2 text-sm text-gray-300 mb-4 cursor-pointer select-none">
              <input type="checkbox" name="has_quantity" value="true" checked={@counter_has_quantity} class="checkbox checkbox-sm" />
              Has quantity
            </label>
            <div class="flex gap-2 justify-end">
              <button type="button" phx-click="cancel_add_counter" class="btn btn-ghost btn-sm">
                Cancel
              </button>
              <button type="submit" class={["btn btn-primary btn-sm", if(!counter_valid, do: "btn-disabled opacity-50 pointer-events-none")]} disabled={!counter_valid}>Add</button>
            </div>
          </form>
        </div>
      </div>

      <%!-- Die Roll Modal --%>
      <%= if @die_roll_modal && is_map(@game_state["die_roll"]) do %>
        <% die = @game_state["die_roll"] %>
        <% player_keys = State.all_player_keys(@game_state) %>
        <% winner_key = Enum.max_by(player_keys, fn k -> die[k] || 0 end) %>
        <% winner_name = get_in(@game_state, [winner_key, "username"]) || winner_key %>
        <%!-- Pip positions for each face of a d6, as {cx, cy} pairs --%>
        <% pip_layouts = %{
          1 => [{50, 50}],
          2 => [{25, 25}, {75, 75}],
          3 => [{25, 25}, {50, 50}, {75, 75}],
          4 => [{25, 25}, {75, 25}, {25, 75}, {75, 75}],
          5 => [{25, 25}, {75, 25}, {50, 50}, {25, 75}, {75, 75}],
          6 => [{25, 22}, {75, 22}, {25, 50}, {75, 50}, {25, 78}, {75, 78}]
        } %>
        <div class="fixed inset-0 bg-black/80 flex items-center justify-center z-50">
          <div class="bg-gray-800 rounded-xl p-8 w-full max-w-md mx-4 text-center shadow-2xl">
            <h2 class="text-2xl font-bold mt-2">Die Roll</h2>
            <div style="height: 1.5rem;"></div>
            <div class="flex justify-around items-start mb-8">
              <%= for pk <- player_keys do %>
                <% pk_name = get_in(@game_state, [pk, "username"]) || pk %>
                <% pk_dice = die["#{pk}_dice"] || [] %>
                <% pk_total = die[pk] || 0 %>
                <div class="flex flex-col items-center gap-3 flex-1">
                  <span class="text-base text-gray-300 font-medium">{pk_name}</span>
                  <div class="flex flex-wrap justify-center gap-1">
                    <%= for d <- pk_dice do %>
                      <svg viewBox="0 0 100 100" width="72" height="72" class="rounded-xl" style="background:#1e293b; border: 3px solid #475569;">
                        <%= for {cx, cy} <- Map.get(pip_layouts, d, []) do %>
                          <circle cx={cx} cy={cy} r="9" fill="white"/>
                        <% end %>
                      </svg>
                    <% end %>
                  </div>
                  <span class="text-lg font-bold text-white">{pk_total}</span>
                </div>
              <% end %>
            </div>
            <p class="text-lg font-semibold mb-6">
              <span class="text-green-400">{winner_name}</span> goes first!
            </p>
            <button phx-click="dismiss_die_roll" class="btn btn-primary w-full">
              Start Playing
            </button>
          </div>
        </div>
      <% end %>

      <%!-- End Game Modal --%>
      <div
        :if={@end_game_modal}
        class="fixed inset-0 bg-black/80 flex items-center justify-center z-50"
      >
        <div class="bg-gray-800 rounded-xl p-6 w-80 mx-4 text-center">
          <h2 class="text-xl font-bold mb-2">End Game?</h2>
          <p class="text-gray-400 text-sm mb-6">
            End the game for both players.
          </p>
          <div class="flex flex-col gap-3">
            <button phx-click="play_again_with_sideboard" class="btn btn-primary w-full">
              Play Again (with Sideboarding)
            </button>
            <div class="flex gap-3 justify-center">
              <button phx-click="cancel_end_game" class="btn btn-ghost flex-1">Cancel</button>
              <button phx-click="confirm_end_game" class="btn btn-error flex-1">End Game</button>
            </div>
          </div>
        </div>
      </div>

      <%!-- Sideboard Modal --%>
      <%= if @sideboard_modal && @sideboard_deck do %>
        <% sb_name = fn dc -> (Map.get(@sideboard_card_map, dc.oracle_id) || %{name: dc.oracle_id}).name end %>
        <% main_cards = Enum.filter(@sideboard_deck.deck_cards, &(&1.board == "main")) |> Enum.sort_by(sb_name) %>
        <% side_cards = Enum.filter(@sideboard_deck.deck_cards, &(&1.board == "sideboard")) |> Enum.sort_by(sb_name) %>
        <% already_submitted = get_in(@game.game_state, ["sideboard_ready", @my_role]) == true %>
        <div class="fixed inset-0 bg-black/80 flex items-center justify-center z-50">
          <div id="sideboard-modal" phx-hook="CardPreview" class="bg-gray-800 rounded-xl p-6 w-full max-w-2xl mx-4 max-h-[90vh] flex flex-col">
            <div class="flex items-center justify-between mb-4">
              <h2 class="text-xl font-bold">Sideboarding</h2>
              <%= if already_submitted do %>
                <span class="text-green-400 text-sm">Submitted — waiting for opponent...</span>
              <% else %>
                <span class="text-yellow-400 text-sm">Move cards between deck and sideboard</span>
              <% end %>
            </div>

            <div class="flex gap-4 flex-1 min-h-0">
              <%!-- Main Deck --%>
              <div class="flex-1 flex flex-col min-h-0">
                <h3 class="text-sm font-semibold text-gray-400 mb-2">Main Deck ({Enum.sum(Enum.map(main_cards, & &1.quantity))})</h3>
                <div class="overflow-y-auto flex-1 space-y-0.5">
                  <%= for dc <- main_cards do %>
                    <% card_img = sideboard_card_img(@sideboard_card_map, dc.oracle_id, dc.printing_id) %>
                    <div class="flex items-center gap-2 text-sm py-0.5">
                      <span class="text-gray-400 w-6 text-right shrink-0 tabular-nums">{dc.quantity}x</span>
                      <span
                        class="flex-1 text-white truncate"
                        data-card-img={card_img}
                      >{sb_name.(dc)}</span>
                      <%= if !already_submitted do %>
                        <button
                          phx-hook="SideboardButton"
                          id={"sb-main-#{dc.id}"}
                          data-id={dc.id}
                          data-to-board="sideboard"
                          class="text-xs bg-gray-700 hover:bg-purple-600 text-gray-300 hover:text-white px-2 py-0.5 rounded shrink-0 cursor-pointer"
                          title="Move to sideboard"
                        >→</button>
                      <% end %>
                    </div>
                  <% end %>
                </div>
              </div>

              <%!-- Sideboard --%>
              <div class="flex-1 flex flex-col min-h-0">
                <h3 class="text-sm font-semibold text-gray-400 mb-2">Sideboard ({Enum.sum(Enum.map(side_cards, & &1.quantity))})</h3>
                <div class="overflow-y-auto flex-1 space-y-0.5">
                  <%= for dc <- side_cards do %>
                    <% card_img = sideboard_card_img(@sideboard_card_map, dc.oracle_id, dc.printing_id) %>
                    <div class="flex items-center gap-2 text-sm py-0.5">
                      <%= if !already_submitted do %>
                        <button
                          phx-hook="SideboardButton"
                          id={"sb-side-#{dc.id}"}
                          data-id={dc.id}
                          data-to-board="main"
                          class="text-xs bg-gray-700 hover:bg-purple-600 text-gray-300 hover:text-white px-2 py-0.5 rounded shrink-0 cursor-pointer"
                          title="Move to main deck"
                        >←</button>
                      <% end %>
                      <span class="text-gray-400 w-6 text-right shrink-0 tabular-nums">{dc.quantity}x</span>
                      <span
                        class="flex-1 text-white truncate"
                        data-card-img={card_img}
                      >{sb_name.(dc)}</span>
                    </div>
                  <% end %>
                </div>
              </div>
            </div>

            <div class="flex gap-3 mt-4 justify-between">
              <%= if !already_submitted do %>
                <button phx-click="reset_sideboard" class="btn btn-ghost btn-sm">Reset to Original</button>
                <button phx-click="submit_sideboard" class="btn btn-primary btn-sm">Submit</button>
              <% end %>
            </div>
          </div>
        </div>
      <% end %>
    </div>
    """
  end
end
