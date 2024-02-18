defmodule AWS.CodeGen.RestService do
  alias AWS.CodeGen.Docstring
  alias AWS.CodeGen.Service
  alias AWS.CodeGen.Shapes

  defmodule Action do
    alias AWS.CodeGen.RestService.Parameter

    defstruct arity: nil,
              docstring: nil,
              method: nil,
              request_uri: nil,
              success_status_code: nil,
              function_name: nil,
              name: nil,
              url_parameters: [],
              query_parameters: [],
              required_query_parameters: [],
              request_header_parameters: [],
              request_headers_parameters: [],
              required_request_header_parameters: [],
              response_header_parameters: [],
              send_body_as_binary?: false,
              receive_body_as_binary?: false,
              host_prefix: nil,
              language: nil

    def method(action) do
      result = action.method |> String.downcase() |> String.to_atom()
      "#{if action.language == :elixir, do: ":", else: ""}#{result}"
    end

    def url_path(action) do
      Enum.reduce(action.url_parameters, action.request_uri, fn parameter, acc ->
        multi_segment = Parameter.multi_segment?(parameter, acc)

        name =
          if action.language == :elixir do
            if multi_segment do
              Enum.join([
                ~S(#{),
                "AWS.Util.encode_multi_segment_uri(",
                parameter.code_name,
                ")",
                ~S(})
              ])
            else
              Enum.join([~S(#{), "AWS.Util.encode_uri(", parameter.code_name, ")", ~S(})])
            end
          else
            if multi_segment do
              Enum.join(["\", aws_util:encode_multi_segment_uri(", parameter.code_name, "), \""])
            else
              Enum.join(["\", aws_util:encode_uri(", parameter.code_name, "), \""])
            end
          end

        # Some url parameters have a trailing "+" indicating they are
        # multi-segment. This regex takes that into account.
        {:ok, re} = Regex.compile("{#{parameter.location_name}\\+?}")
        String.replace(acc, re, name)
      end)
    end
  end

  defmodule Context do
    def s3_context?(context) do
      context.endpoint_prefix == "s3" and context.endpoint_prefix != "s3-control"
    end
  end

  defmodule Parameter do
    defstruct code_name: nil,
              name: nil,
              location_name: nil,
              required: false

    def multi_segment?(parameter, request_uri) do
      {:ok, re} = Regex.compile("{#{parameter.location_name}\\+}")
      String.match?(request_uri, re)
    end
  end

  @configuration %{
    :rest_xml => %{
      content_type: "text/xml",
      elixir: %{
        decode: "xml",
        encode: "xml"
      },
      erlang: %{
        decode: "aws_util:decode_xml(Body)",
        encode: "aws_util:encode_xml(Input)"
      }
    },
    :rest_json => %{
      content_type: "application/x-amz-json-1.1",
      elixir: %{
        decode: "json",
        encode: "json"
      },
      erlang: %{
        decode: "jsx:decode(Body)",
        encode: "jsx:encode(Input)"
      }
    }
  }

  @doc """
  Load REST API service and documentation specifications from the
  `api_spec_path` and `doc_spec_path` files and convert them into a context
  that can be used to generate code for an AWS service.  `language` must be
  `:elixir` or `:erlang`.
  """
  def load_context(language, %AWS.CodeGen.Spec{} = spec, endpoints_spec) do
    service = spec.api["shapes"][spec.shape_name]
    traits = service["traits"]
    actions = collect_actions(language, spec.api)
    protocol = spec.protocol |> IO.inspect(label: "protocol")
    endpoint_prefix = traits["aws.api#service"]["endpointPrefix"] || traits["aws.api#service"]["arnNamespace"] ##TODO: for some reason this field is not always present and docs are not clear on what to do
    endpoint_info = endpoints_spec["services"][endpoint_prefix]
    is_global = not is_nil(endpoint_info) and not Map.get(endpoint_info, "isRegionalized", true)

    credential_scope =
      if is_global do
        endpoint_info["endpoints"]["aws-global"]["credentialScope"]["region"]
      end

    ## TODO: this is wrong because it could also be sigv4a or else
    signing_name = traits["aws.auth#sigv4"]["name"] || endpoint_prefix

    %Service{
      actions: actions,
      api_version: service["version"],
      docstring: Docstring.format(language, "placeholder docs"), ##TODO: proper docs spec.doc["service"]),
      credential_scope: credential_scope,
      content_type: @configuration[protocol][:content_type],
      decode: Map.fetch!(@configuration[protocol][language], :decode),
      encode: Map.fetch!(@configuration[protocol][language], :encode),
      endpoint_prefix: endpoint_prefix,
      is_global: is_global,
      json_version: get_json_version(traits),
      language: language,
      module_name: spec.module_name,
      protocol: nil, ## TODO: metadata["protocol"],
      signing_name: signing_name,
      signature_version: get_signature_version(traits),
      service_id: traits["aws.api#service"]["sdkId"],
      target_prefix: nil, ##TODO: metadata["targetPrefix"]
    }
  end

  @doc """
  Render required function parameters, if any, in a way that can be inserted directly
  into the code template.
  """
  def required_function_parameters(action) do
    function_parameters(action, true)
  end

  @doc """
  Render function parameters, if any, in a way that can be inserted directly
  into the code template. It can be asked to only return the required ones.
  """
  def function_parameters(action, required_only \\ false) do
    language = action.language

    Enum.join([
      join_parameters(action.url_parameters, language)
      | case action.method do
          "GET" ->
            case required_only do
              false ->
                [
                  join_parameters(action.query_parameters, language),
                  join_parameters(action.request_header_parameters, language),
                  join_parameters(action.request_headers_parameters, language)
                ]

              true ->
                [
                  join_parameters(action.required_query_parameters, language),
                  join_parameters(action.required_request_header_parameters, language)
                ]
            end

          _ ->
            []
        end
    ])
  end

  defp join_parameters(parameters, language) do
    Enum.join(
      Enum.map(
        parameters,
        fn parameter ->
          if not parameter.required and language == :elixir do
            ", #{parameter.code_name} \\\\ nil"
          else
            ", #{parameter.code_name}"
          end
        end
      )
    )
  end

  defp collect_actions(language, api_spec) do
    shapes = api_spec["shapes"]

    operations =
      Enum.reduce(shapes, [], fn {_, shape}, acc ->
        case shape["type"] do
          "service" ->

            (shape["operations"] || []) ++ acc
          "resource" ->
            [shape["operations"], shape["collectionOperations"], shape["create"], shape["put"], shape["read"], shape["update"], shape["delete"], shape["list"]]
            |> Enum.reject(&is_nil/1)
            |> Kernel.++(acc)
          _ ->
            acc
        end
      end)
      |> List.flatten()
      |> Enum.map(fn %{"target" => target} -> target end)

    Enum.map(operations, fn operation ->
      operation_spec = shapes[operation]

      url_parameters = collect_url_parameters(language, api_spec, operation)
      query_parameters = collect_query_parameters(language, api_spec, operation)
      request_header_parameters = collect_request_header_parameters(language, api_spec, operation)

      request_headers_parameters =
        collect_request_headers_parameters(language, api_spec, operation)

      is_required = fn param -> param.required end
      required_query_parameters = Enum.filter(query_parameters, is_required)
      required_request_header_parameters = Enum.filter(request_header_parameters, is_required)
      method = operation_spec["traits"]["smithy.api#http"]["method"]

      len_for_method =
        case method do
          "GET" ->
            case language do
              :elixir ->
                2 + length(request_header_parameters) + length(request_headers_parameters) +
                  length(query_parameters)

              :erlang ->
                4 + length(required_request_header_parameters) + length(required_query_parameters)
            end

          _ ->
            3
        end

      input_shape = Shapes.get_input_shape(operation_spec)
      output_shape = Shapes.get_output_shape(operation_spec)

      %Action{
        arity: length(url_parameters) + len_for_method,
        docstring:
          Docstring.format(
            language,
            "TODO: remove placeholder docs" ##doc_spec["operations"][operation]
          ),
        method: method,
        request_uri: operation_spec["traits"]["smithy.api#http"]["uri"],
        success_status_code: operation_spec["traits"]["smithy.api#http"]["code"],
        function_name: AWS.CodeGen.Name.to_snake_case(operation),
        name: operation,
        url_parameters: url_parameters,
        query_parameters: query_parameters,
        required_query_parameters: required_query_parameters,
        request_header_parameters: request_header_parameters,
        request_headers_parameters: request_headers_parameters,
        required_request_header_parameters: required_request_header_parameters,
        response_header_parameters:
          collect_response_header_parameters(language, api_spec, operation),
        send_body_as_binary?: Shapes.body_as_binary?(shapes, input_shape),
        receive_body_as_binary?: Shapes.body_as_binary?(shapes, output_shape),
        host_prefix: get_in(operation_spec, ["endpoint", "hostPrefix"]),
        language: language
      }
    end)
    |> Enum.sort(fn a, b -> a.function_name < b.function_name end)
  end

  defp collect_url_parameters(language, api_spec, operation) do
    collect_parameters(language, api_spec, operation, "input", "uri")
  end

  defp collect_query_parameters(language, api_spec, operation) do
    collect_parameters(language, api_spec, operation, "input", "querystring")
  end

  defp collect_request_header_parameters(language, api_spec, operation) do
    collect_parameters(language, api_spec, operation, "input", "header")
  end

  defp collect_request_headers_parameters(language, api_spec, operation) do
    collect_parameters(language, api_spec, operation, "input", "headers")
  end

  defp collect_response_header_parameters(language, api_spec, operation) do
    collect_parameters(language, api_spec, operation, "output", "header")
  end

  defp collect_parameters(language, api_spec, operation, data_type, param_type) do
    shape_name = api_spec["operations"][operation][data_type]["shape"]

    if shape_name do
      case api_spec["shapes"][shape_name] do
        nil ->
          []

        shape ->
          required_members = Access.get(shape, "required", [])

          shape["members"]
          |> Enum.filter(filter_fn(param_type))
          |> Enum.map(fn {name, _} = x ->
            required = Enum.member?(required_members, name)
            build_parameter(language, x, required)
          end)
      end
    else
      []
    end
  end

  defp filter_fn(location) do
    fn {_name, member_spec} ->
      case member_spec["location"] do
        ^location -> true
        _ -> false
      end
    end
  end

  defp build_parameter(language, {name, data}, required) do
    %Parameter{
      code_name:
        if language == :elixir do
          AWS.CodeGen.Name.to_snake_case(name)
        else
          AWS.CodeGen.Name.upcase_first(name)
        end,
      name: name,
      location_name: data["locationName"],
      required: required
    }
  end

  defp get_json_version(traits) do
    IO.inspect(traits)
    ["aws.protocols#" <> protocol] = Enum.filter(Map.keys(traits), &String.starts_with?(&1, "aws.protocols#"))
    case protocol do
      "restJson1" -> "1.1" ## TODO: according to the docs this should result in application/json but our current code will make it application/x-amz-json-1.1
      "awsJson1_0" -> "1.0"
      "awsJson1_1" -> "1.1"
      "restXml" -> nil
    end
  end

  defp get_signature_version(traits) do
    signature = Enum.filter(Map.keys(traits), &String.starts_with?(&1, "aws.auth#"))
    case signature do
      ["aws.auth#sig" <> version] -> version
      [] -> nil
    end
  end
end
