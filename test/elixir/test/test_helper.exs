ExUnit.configure(exclude: [pending: true])
ExUnit.start()

defmodule CouchTestCase do
  use ExUnit.Case

  defmacro __using__(_opts) do
    quote do
      require Logger
      use ExUnit.Case

      setup context do
        setup_funs = [
          &set_db_context/1,
          &set_config_context/1,
          &set_user_context/1
        ]
        context = Enum.reduce(setup_funs, context, fn setup_fun, acc ->
          setup_fun.(acc)
        end)
        {:ok, context}
      end

      def set_db_context(context) do
        context = case context do
          %{:with_db_name => true} ->
            Map.put(context, :db_name, random_db_name())
          %{:with_db_name => db_name} when is_binary(db_name) ->
            Map.put(context, :db_name, db_name)
          %{:with_random_db => db_name} when is_binary(db_name) ->
            context
            |> Map.put(:db_name, random_db_name(db_name))
            |> Map.put(:with_db, true)
          %{:with_db => true} ->
            Map.put(context, :db_name, random_db_name())
          %{:with_db => db_name} when is_binary(db_name) ->
            Map.put(context, :db_name, db_name)
          _ ->
            context
        end

        if Map.has_key? context, :with_db do
          {:ok, _} = create_db(context[:db_name])
          on_exit(fn -> delete_db(context[:db_name]) end)
        end

        context
      end

      def set_config_context(context) do
        if is_list(context[:config]) do
          Enum.each(context[:config], fn cfg ->
            set_config(cfg)
          end)
        end
        context
      end

      def set_user_context(context) do
        case Map.get(context, :user) do
          nil ->
            context
          user when is_list(user) ->
            user = create_user(user)
            on_exit(fn ->
              query = %{:rev => user["_rev"]}
              resp = Couch.delete("/_users/#{user["_id"]}", query: query)
              assert HTTPotion.Response.success? resp
            end)
            context = Map.put(context, :user, user)
            userinfo = user["name"] <> ":" <> user["password"]
            Map.put(context, :userinfo, userinfo)
        end
      end

      def random_db_name do
        random_db_name("random-test-db")
      end

      def random_db_name(prefix) do
        time = :erlang.monotonic_time()
        umi = :erlang.unique_integer([:monotonic])
        "#{prefix}-#{time}-#{umi}"
      end

      def set_config({section, key, value}) do
        existing = set_config_raw(section, key, value)
        on_exit(fn ->
          Enum.each(existing, fn {node, prev_value} ->
            if prev_value != "" do
              url = "/_node/#{node}/_config/#{section}/#{key}"
              headers = ["X-Couch-Persist": "false"]
              body = :jiffy.encode(prev_value)
              resp = Couch.put(url, headers: headers, body: body)
              assert resp.status_code == 200
            else
              url = "/_node/#{node}/_config/#{section}/#{key}"
              headers = ["X-Couch-Persist": "false"]
              resp = Couch.delete(url, headers: headers)
              assert resp.status_code == 200
            end
          end)
        end)
      end

      def set_config_raw(section, key, value) do
        resp = Couch.get("/_membership")
        Enum.map(resp.body["all_nodes"], fn node ->
          url = "/_node/#{node}/_config/#{section}/#{key}"
          headers = ["X-Couch-Persist": "false"]
          body = :jiffy.encode(value)
          resp = Couch.put(url, headers: headers, body: body)
          assert resp.status_code == 200
          {node, resp.body}
        end)
      end

      def create_user(user) do
        required = [:name, :password, :roles]
        Enum.each(required, fn key ->
          assert Keyword.has_key?(user, key), "User missing key: #{key}"
        end)

        name = Keyword.get(user, :name)
        password = Keyword.get(user, :password)
        roles = Keyword.get(user, :roles)

        assert is_binary(name), "User name must be a string"
        assert is_binary(password), "User password must be a string"
        assert is_list(roles), "Roles must be a list of strings"
        Enum.each(roles, fn role ->
          assert is_binary(role), "Roles must be a list of strings"
        end)

        user_doc = %{
          "_id" => "org.couchdb.user:" <> name,
          "type" => "user",
          "name" => name,
          "roles" => roles,
          "password" => password
        }
        resp = Couch.get("/_users/#{user_doc["_id"]}")
        user_doc = case resp.status_code do
          404 ->
            user_doc
          sc when sc >= 200 and sc < 300 ->
            Map.put(user_doc, "_rev", resp.body["_rev"])
        end
        resp = Couch.post("/_users", body: user_doc)
        assert HTTPotion.Response.success? resp
        assert resp.body["ok"]
        Map.put(user_doc, "_rev", resp.body["rev"])
      end

      def create_db(db_name) do
        resp = Couch.put("/#{db_name}")
        assert resp.status_code == 201
        assert resp.body == %{"ok" => true}
        {:ok, resp}
      end

      def delete_db(db_name) do
        resp = Couch.delete("/#{db_name}")
        assert resp.status_code == 200
        assert resp.body == %{"ok" => true}
        {:ok, resp}
      end

      def create_doc(db_name, body) do
        resp = Couch.post("/#{db_name}", [body: body])
        assert resp.status_code == 201
        assert resp.body["ok"]
        {:ok, resp}
      end

      def sample_doc_foo do
        %{
          "_id": "foo",
          "bar": "baz"
        }
      end

      def make_docs(id, count) do
        for i <- id..count do
          %{
            :_id => Integer.to_string(i),
            :integer => i,
            :string => Integer.to_string(i)
          }
        end
      end
    end
  end
end