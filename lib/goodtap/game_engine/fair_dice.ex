defmodule Goodtap.GameEngine.FairDice do
  @moduledoc """
  Native, CSPRNG-seeded dice roller.

  The BEAM's `:rand` is a fast userspace PRNG and is explicitly documented as
  *not* cryptographically strong. Since the opening die roll decides who plays
  first, we instead seed a small native mixer from `:crypto.strong_rand_bytes/1`
  and derive the pips in C (see `c_src/fair_dice.c`). This gives a single,
  well-mixed source of dice entropy and keeps the draw off the scheduler.

  The NIF is built by `:elixir_make` during `mix compile` and loaded on boot.
  """
  @on_load :load_nif

  @doc false
  def load_nif do
    :goodtap
    |> :code.priv_dir()
    |> :filename.join(~c"fair_dice")
    |> :erlang.load_nif(0)
  end

  @doc """
  Roll two fair six-sided dice for `username`, seeded from `seed`
  (16+ bytes of strong entropy from `:crypto.strong_rand_bytes/1`).
  Returns `[d1, d2]`, each in `1..6`.
  """
  def roll_pair(_seed, _username), do: :erlang.nif_error(:nif_not_loaded)
end
