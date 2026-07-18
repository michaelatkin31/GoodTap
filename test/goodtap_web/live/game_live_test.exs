defmodule GoodtapWeb.GameLiveTest do
  use GoodtapWeb.ConnCase, async: false

  import Phoenix.LiveViewTest
  import Goodtap.AccountsFixtures

  alias Goodtap.GameFixtures
  alias Goodtap.Games
  alias Goodtap.GameEngine.State

  # Build a 2-player active game (host -> p1, guest -> p2) whose opponent (p2)
  # hand holds the given cards, then return the freshly-loaded game.
  defp game_with_opp_hand(host, guest, opp_hand_cards) do
    {:ok, game} = Games.create_game(host, max_players: 2)
    {:ok, game, "p2"} = Games.join_game(game, guest)

    state =
      GameFixtures.game_state(
        %{"username" => host.username},
        %{"username" => guest.username}
      )
      |> GameFixtures.with_cards_in("p2", "hand", opp_hand_cards)

    {:ok, game} = Games.update_game_state(game, state)
    {:ok, game} = Games.start_game(game)
    game
  end

  describe "opponent hand card previews" do
    test "a card revealed to me carries data-card-img so it can be highlighted", %{conn: conn} do
      host = user_fixture()
      guest = user_fixture()

      revealed =
        GameFixtures.card(%{
          "name" => "Revealed Card",
          "image_uris" => %{"front" => "https://example.com/revealed.jpg", "back" => nil},
          "known" => %{"p1" => true}
        })

      game = game_with_opp_hand(host, guest, [revealed])

      {:ok, _view, html} = live(log_in_user(conn, host), ~p"/games/#{game.id}/play")

      assert html =~ ~s(data-card-img="https://example.com/revealed.jpg")
    end

    test "a card not revealed to me shows the card back and is not highlightable", %{conn: conn} do
      host = user_fixture()
      guest = user_fixture()

      hidden =
        GameFixtures.card(%{
          "name" => "Hidden Card",
          "image_uris" => %{"front" => "https://example.com/hidden.jpg", "back" => nil},
          "known" => %{}
        })

      game = game_with_opp_hand(host, guest, [hidden])

      {:ok, _view, html} = live(log_in_user(conn, host), ~p"/games/#{game.id}/play")

      # The hidden card renders as the card back...
      assert html =~ State.card_back_url()
      # ...and its real front image is never exposed, in src or as a preview target.
      refute html =~ "https://example.com/hidden.jpg"
    end
  end
end
