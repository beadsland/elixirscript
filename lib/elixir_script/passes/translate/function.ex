defmodule ElixirScript.Translate.Function do
  @moduledoc false

  # Translates the given Elixir function AST into the
  # equivalent JavaScript AST.

  alias ESTree.Tools.Builder, as: J
  alias ElixirScript.Translate.{Clause, Form, Helpers}
  alias ElixirScript.Translate.Forms.Pattern

  @spec compile(any, map) :: {ESTree.Node.t, map}

  def compile(any, map) do
    super_compile(any, map)
  rescue
    e ->  logbug(any, map)
          reraise e, __STACKTRACE__
  end

  require Logger

  def logbug({func, type, _, clauses}, state) do
    logbug({func, type, clauses}, state)
  end
  def logbug({func, type, [{line, _, _, _} | _]}, state) do
    logbug({func, type}, line[:line], state)
  end
  def logbug({func, type, [{_, line, _} | _]}, state) do
    logbug({func, type}, line[:line], state)
  end

  def logbug({{name, nil}, type}, line, state) do
    logbug({type, "#{name}"}, line, state)
  end
  def logbug({{name, arity}, type}, line, state) do
    logbug({type, "#{name}/#{arity}"}, line, state)
  end

  def logbug(func, line, %{:function => statefunc, :arity => statearity} = state) do
    statefunc = "#{statefunc}/#{statearity}"
    logbug(func, line, state, "#{state.module}.#{statefunc}")
  end
  def logbug(func, line, state) do
    logbug(func, line, state, "#{state.module}")
  end

  def logbug({:fn, _}, line, _state, modpath)  do
    Logger.warn "elixirscript: compiling #{modpath}, :fn at line #{line}..."
  end
  def logbug({type, func}, line, _state, modpath) do
    Logger.warn "elixirscript: compiling #{modpath}.#{func}, #{type} at line #{line}..."
  end

  def super_compile({:fn, _, clauses}, state) do
    anonymous? = Map.get(state, :anonymous_fn, false)

    state = Map.put(state, :anonymous_fn, true)
    |> Map.put(:in_guard, false)

    clauses = compile_clauses(clauses, state)

    arg_matches_declaration = Helpers.declare_let("__arg_matches__", J.identifier("null"))

    function_recur_dec = Helpers.function(
      "recur",
      [J.rest_element(J.identifier("__function_args__"))],
      J.block_statement([
        arg_matches_declaration,
        clauses,
        J.throw_statement(
          Helpers.new(
            J.member_expression(
              Helpers.patterns(),
              J.identifier("MatchError")
            ),
            [J.identifier("__function_args__")]
          )
        )
      ])
    )

    function_dec = Helpers.arrow_function(
      [J.rest_element(J.identifier("__function_args__"))],
      J.block_statement([
        function_recur_dec,
        J.return_statement(
          trampoline()
        )
      ])
    )

    state = Map.put(state, :anonymous_fn, anonymous?)
    { function_dec, state }
  end

  def super_compile({{name, arity}, _type, _, clauses}, state) do

    state = Map.put(state, :function, {name, arity})
    |> Map.put(:anonymous_fn, false)
    |> Map.put(:in_guard, false)

    clauses = compile_clauses(clauses, state)

    arg_matches_declaration = Helpers.declare_let("__arg_matches__", J.identifier("null"))
    intermediate_declaration = Helpers.declare_let("__intermediate__", J.identifier("null"))

    function_recur_dec = Helpers.function(
      "recur",
      [J.rest_element(J.identifier("__function_args__"))],
      J.block_statement([
        arg_matches_declaration,
        intermediate_declaration,
        clauses,
        J.throw_statement(
          Helpers.new(
            J.member_expression(
              Helpers.patterns(),
              J.identifier("MatchError")
            ),
            [J.identifier("__function_args__")]
          )
        )
      ])
    )

    function_dec = Helpers.function(
      ElixirScript.Translate.Identifier.make_function_name(name),
      [J.rest_element(J.identifier("__function_args__"))],
      J.block_statement([
        function_recur_dec,
        J.return_statement(
          trampoline()
        )
      ])
    )

    { function_dec, state }
  end

  defp compile_clauses(clauses, state) do
    clauses
    |> Enum.map(&compile_clause(&1, state))
    |> Enum.map(fn {patterns, _params, guards, body} ->
      match_or_default_call = Helpers.call(
        J.member_expression(
          Helpers.patterns(),
          J.identifier("match_or_default")
        ),
        [J.array_expression(patterns), J.identifier("__function_args__"), guards]
      )

      J.if_statement(
        J.binary_expression(
          :!==,
          Helpers.assign(J.identifier("__arg_matches__"), match_or_default_call),
          J.identifier("null")
        ),
        J.block_statement(body)
      )
    end)
    |> Enum.reverse
    |> Enum.reduce(nil, fn
      if_ast, nil ->
        if_ast
      if_ast, ast ->
        %{if_ast | alternate: ast}
    end)
  end

  defp compile_clause({ _, args, guards, body}, state) do
    state = if Map.has_key?(state, :vars) do
      state
    else
      Map.put(state, :vars, %{})
    end

    {patterns, params, state} = Pattern.compile(args, state)
    guard = Clause.compile_guard(params, guards, state)

    {body, _state} = compile_block(body, state)

    body = body
    |> Clause.return_last_statement
    |> update_last_call(state)

    declaration = Helpers.declare_let(params, J.identifier("__arg_matches__"))

    body = [declaration] ++ body
    {patterns, params, guard, body}
  end

  defp compile_clause({:->, _, [[{:when, _, params}], body ]}, state) do
    guards = List.last(params)
    params = params |> Enum.reverse |> tl |> Enum.reverse

    compile_clause({[], params, guards, body}, state)
  end

  defp compile_clause({:->, _, [params, body]}, state) do
    compile_clause({[], params, [], body}, state)
  end

  @spec compile_block(any, map) :: {ESTree.Node.t, map}
  def compile_block(block, state) do
    ast = case block do
      nil ->
        J.identifier("null")
      {:__block__, _, block_body} ->
        {list, _} = Enum.map_reduce(block_body, state, &Form.compile(&1, &2))
        List.flatten(list)
      _ ->
        Form.compile!(block, state)
    end

    {ast, state}
  end

  @spec update_last_call([ESTree.Node.t], map) :: list
  def update_last_call(clause_body, %{function: {name, _}, anonymous_fn: anonymous?}) do
    last_item = List.last(clause_body)
    function_name = ElixirScript.Translate.Identifier.make_function_name(name)

    case last_item do
      %ESTree.ReturnStatement{ argument: %ESTree.CallExpression{ callee: ^function_name, arguments: arguments } } ->
        if anonymous? do
          clause_body
        else
          new_last_item = J.return_statement(
            recurse(
              recur_bind(arguments)
            )
          )

          List.replace_at(clause_body, length(clause_body) - 1, new_last_item)
        end
      _ ->
        clause_body
    end
  end

  defp recur_bind(args) do
    Helpers.call(
      J.member_expression(
        J.identifier("recur"),
        J.identifier("bind")
      ),
      [J.identifier("null")] ++ args
    )
  end

  defp recurse(func) do
    Helpers.new(
      J.member_expression(
        Helpers.functions(),
        J.identifier("Recurse")
      ),
      [
        func
      ]
    )
  end

  defp trampoline() do
    Helpers.call(
      J.member_expression(
        Helpers.functions(),
        J.identifier("trampoline")
      ),
      [
        recurse(
          recur_bind([J.rest_element(J.identifier("__function_args__"))])
        )
      ]
    )
  end
end
