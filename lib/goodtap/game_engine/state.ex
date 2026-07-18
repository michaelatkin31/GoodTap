defmodule Goodtap.GameEngine.State do
  alias Goodtap.Catalog
  alias Goodtap.Decks
  alias Goodtap.GameEngine.FairDice

  @double_faced_layouts ["transform", "modal_dfc", "double_faced_token", "reversible_card"]

  @doc """
  Initialize full game state when all players have selected decks.
  players_with_keys is a list of {player_key, user} tuples (e.g. [{"p1", host}, {"p2", opp}]).
  deck_id_map is %{"p1" => deck_id, "p2" => deck_id, ...}.
  Returns the game_state map ready to be stored in the Game record.
  """
  def initialize(players_with_keys, deck_id_map, opts \\ []) do
    player_states =
      Map.new(players_with_keys, fn {key, user} ->
        {key, build_player_state(user, deck_id_map[key], key)}
      end)

    build_game_state(player_states, opts)
  end

  @doc """
  Initialize game state with explicit card entry lists (used for sideboard restarts).
  card_specs is %{"p1" => {card_entries, commander_entries, deck_id}, "p2" => ...}
  """
  def initialize_with_card_lists(players_with_keys, card_specs, opts \\ []) do
    player_states =
      Map.new(players_with_keys, fn {key, user} ->
        {key, build_player_state_from_entries(user, card_specs[key], key)}
      end)

    build_game_state(player_states, opts)
  end

  def starting_life(player_count) when player_count > 2, do: 40
  def starting_life(_), do: 20

  defp build_game_state(player_states, opts) do
    player_keys = Map.keys(player_states) |> Enum.sort()
    life = starting_life(length(player_keys))

    player_states =
      Map.new(player_states, fn {key, state} -> {key, Map.put(state, "life", life)} end)

    if Keyword.get(opts, :roll_die, true) do
      {die_roll, log} = roll_until_winner(player_keys, player_states)

      player_states
      |> Map.put("die_roll", die_roll)
      |> Map.put("log", log)
    else
      player_states
    end
  end

  defp roll_until_winner(player_keys, player_states) do
    roll_until_winner(player_keys, player_states, player_keys, [])
  end

  defp roll_until_winner(all_keys, player_states, contenders, log_acc) do
    t = System.system_time(:second)

    # Strong per-round entropy handed to the native roller.
    seed = :crypto.strong_rand_bytes(16)

    rolls =
      Enum.map(contenders, fn key ->
        username = get_in(player_states, [key, "username"]) || key
        dice = FairDice.roll_pair(seed, username)
        total = Enum.sum(dice)
        {key, dice, total}
      end)

    round_log =
      Enum.map(rolls, fn {key, _dice, total} ->
        username = get_in(player_states, [key, "username"]) || key
        %{"t" => t, "p" => key, "u" => username, "m" => "rolled a #{total}"}
      end)

    max_total = rolls |> Enum.map(&elem(&1, 2)) |> Enum.max()
    winners = Enum.filter(rolls, fn {_, _, total} -> total == max_total end)
    log_acc = round_log ++ log_acc

    case winners do
      [{_winner_key, _winner_dice, _winner_total}] ->
        # Build die_roll map with all players' rolls
        die_roll =
          Enum.reduce(rolls, %{}, fn {key, dice, total}, acc ->
            acc |> Map.put(key, total) |> Map.put("#{key}_dice", dice)
          end)

        {die_roll, log_acc}

      tied ->
        # Log the tie and reroll among tied players
        tie_log = %{"t" => t, "p" => nil, "u" => "system", "m" => "tie — rerolling"}
        roll_until_winner(all_keys, player_states, Enum.map(tied, &elem(&1, 0)), [tie_log | log_acc])
    end
  end

  defp build_player_state_from_entries(user, {card_entries, commander_entries, deck_id}, role) do
    commander_entries = List.wrap(commander_entries)
    all_oracle_ids = Enum.uniq(Enum.map(card_entries, &elem(&1, 0)) ++ Enum.map(commander_entries, &elem(&1, 0)))
    cards = Catalog.list_cards_by_oracle_ids(all_oracle_ids)
    card_map = Map.new(cards, &{&1.oracle_id, &1})

    instances =
      card_entries
      |> Enum.flat_map(fn {oracle_id, printing_id} ->
        case Map.fetch(card_map, oracle_id) do
          {:ok, card} -> [build_card_instance(card, printing_id)]
          :error ->
            require Logger
            Logger.warning("Card not found in catalog, skipping oracle_id: #{inspect(oracle_id)}")
            []
        end
      end)
      |> Enum.shuffle()

    {hand_raw, deck} = Enum.split(instances, 7)
    hand = Enum.map(hand_raw, &Map.put(&1, "known", %{role => true}))

    battlefield =
      commander_entries
      |> Enum.with_index()
      |> Enum.flat_map(fn {{oracle_id, printing_id}, i} ->
        case Map.fetch(card_map, oracle_id) do
          {:ok, card} ->
            [build_card_instance(card, printing_id) |> Map.put("x", 0.3 + i * 0.1) |> Map.put("y", 0.5)]
          :error ->
            require Logger
            Logger.warning("Starts-in-play card not found in catalog: #{inspect(oracle_id)}")
            []
        end
      end)

    %{
      "user_id" => user.id,
      "username" => user.username,
      "life" => 20,
      "trackers" => [],
      "deck_id" => deck_id,
      "zones" => %{
        "hand" => hand,
        "deck" => deck,
        "battlefield" => battlefield,
        "graveyard" => [],
        "exile" => []
      }
    }
  end

  defp build_player_state(user, deck_id, role) do
    deck_entries = Decks.expand_deck_cards(deck_id)
    commander_entries = Decks.get_commanders(deck_id)
    commander_tuples = Enum.flat_map(commander_entries, fn dc ->
      List.duplicate({dc.oracle_id, dc.printing_id}, dc.quantity)
    end)

    all_oracle_ids = Enum.uniq(Enum.map(deck_entries, &elem(&1, 0)) ++ Enum.map(commander_tuples, &elem(&1, 0)))
    cards = Catalog.list_cards_by_oracle_ids(all_oracle_ids)
    card_map = Map.new(cards, &{&1.oracle_id, &1})

    instances =
      deck_entries
      |> Enum.flat_map(fn {oracle_id, printing_id} ->
        case Map.fetch(card_map, oracle_id) do
          {:ok, card} -> [build_card_instance(card, printing_id)]
          :error ->
            require Logger
            Logger.warning("Card not found in catalog, skipping oracle_id: #{inspect(oracle_id)}")
            []
        end
      end)
      |> Enum.shuffle()

    {hand_raw, deck} = Enum.split(instances, 7)
    hand = Enum.map(hand_raw, &Map.put(&1, "known", %{role => true}))

    # Place all starts-in-play cards on battlefield
    battlefield =
      commander_tuples
      |> Enum.with_index()
      |> Enum.flat_map(fn {{oracle_id, printing_id}, i} ->
        case Map.fetch(card_map, oracle_id) do
          {:ok, card} ->
            [build_card_instance(card, printing_id) |> Map.put("x", 0.3 + i * 0.1) |> Map.put("y", 0.5)]
          :error ->
            require Logger
            Logger.warning("Starts-in-play card not found in catalog: #{inspect(oracle_id)}")
            []
        end
      end)

    %{
      "user_id" => user.id,
      "username" => user.username,
      "life" => 20,
      "trackers" => [],
      "deck_id" => deck_id,
      "zones" => %{
        "hand" => hand,
        "deck" => deck,
        "battlefield" => battlefield,
        "graveyard" => [],
        "exile" => []
      }
    }
  end

  def build_card_instance(card, printing_id \\ nil) do
    is_dfc = card.layout in @double_faced_layouts
    resolved_printing_id = printing_id || card.default_printing_id
    image_uris = printing_image_uris(card, resolved_printing_id) || extract_image_uris(card.data)

    %{
      "instance_id" => Ecto.UUID.generate(),
      "card_id" => card.id,
      "oracle_id" => card.oracle_id,
      "name" => card.name,
      "is_token" => card.layout == "token",
      "is_face_down" => false,
      "active_face" => 0,
      "is_double_faced" => is_dfc,
      "image_uris" => image_uris,
      "counters" => [],
      "tapped" => false,
      "known" => %{}
    }
  end

  def build_token_instance(card, printing_id \\ nil) do
    card
    |> build_card_instance(printing_id)
    |> Map.put("is_token", true)
    |> Map.put("instance_id", Ecto.UUID.generate())
  end

  defp printing_image_uris(_card, nil), do: nil
  defp printing_image_uris(card, printing_id) do
    case Enum.find(card.printings, &(&1["id"] == printing_id)) do
      nil -> nil
      printing ->
        front = get_in(printing, ["image_uris", "normal"])
        back = get_in(card.data, ["card_faces", Access.at(1), "image_uris", "normal"])
        %{"front" => front, "back" => back}
    end
  end

  defp extract_image_uris(card_data) do
    cond do
      Map.has_key?(card_data, "image_uris") ->
        %{
          "front" => get_in(card_data, ["image_uris", "normal"]),
          "back" => nil
        }

      match?(%{"card_faces" => [_, _ | _]}, card_data) ->
        [face0, face1 | _] = card_data["card_faces"]

        %{
          "front" => get_in(face0, ["image_uris", "normal"]),
          "back" => get_in(face1, ["image_uris", "normal"])
        }

      true ->
        %{"front" => nil, "back" => nil}
    end
  end

  @doc """
  Returns the card back URL used for face-down or hidden cards.
  """
  def card_back_url do
    "/images/CardBack.png"
  end

  @doc """
  Returns true if the card is known to the given role.
  """
  def known_to?(card, role) do
    case card["known"] do
      map when is_map(map) -> map[role] == true
      _ -> false
    end
  end

  @doc """
  Returns all player keys present in a game state (top-level keys starting with "p").
  """
  def all_player_keys(state) do
    state
    |> Map.keys()
    |> Enum.filter(&String.starts_with?(&1, "p"))
    |> Enum.sort()
  end

  @doc """
  Returns all battlefield cards visible to a viewer, as {card, owner_key} tuples.

  A viewer sees all cards whose effective battlefield (on_battlefield field, or owner
  if absent) equals either my_role or viewed_opponent. Orientation is determined by
  the caller: render upright if owner_key == my_role, flipped otherwise.
  """
  def battlefield_for_view(game_state, my_role, viewed_opponent) do
    all_player_keys(game_state)
    |> Enum.flat_map(fn owner_key ->
      game_state
      |> get_in([owner_key, "zones", "battlefield"])
      |> Kernel.||([])
      |> Enum.filter(fn card ->
        effective_bf = card["on_battlefield"] || owner_key
        effective_bf == my_role or effective_bf == viewed_opponent
      end)
      |> Enum.map(&{&1, owner_key})
    end)
  end

  @doc """
  Determine the display image URL for a card given viewer perspective.
  """
  def card_display_url(card_instance, viewer_role, owner_role, zone) do
    cond do
      zone == "hand" and viewer_role != owner_role and not known_to?(card_instance, viewer_role) ->
        card_back_url()

      zone == "deck" and not known_to?(card_instance, viewer_role) ->
        card_back_url()

      card_instance["is_face_down"] ->
        card_back_url()

      card_instance["active_face"] == 1 ->
        card_instance["image_uris"]["back"] || card_back_url()

      true ->
        card_instance["image_uris"]["front"] || card_back_url()
    end
  end


end
