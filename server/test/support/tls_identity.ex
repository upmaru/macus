defmodule Macus.TestSupport.TLSIdentity do
  @moduledoc "Disposable CA-signed identity for isolated TLS fixtures."

  def generate(root, name, hostname) do
    certfile = Path.join(root, name <> ".pem")
    keyfile = Path.join(root, name <> ".key")
    cafile = Path.join(root, name <> "-ca.pem")
    cakey = Path.join(root, name <> "-ca.key")
    csr = Path.join(root, name <> ".csr")
    extensions = Path.join(root, name <> ".extensions")

    run!([
      "req",
      "-x509",
      "-newkey",
      "ec",
      "-pkeyopt",
      "ec_paramgen_curve:P-256",
      "-nodes",
      "-days",
      "1",
      "-subj",
      "/CN=#{name}-fixture-ca",
      "-addext",
      "basicConstraints=critical,CA:TRUE",
      "-keyout",
      cakey,
      "-out",
      cafile
    ])

    run!([
      "req",
      "-new",
      "-newkey",
      "ec",
      "-pkeyopt",
      "ec_paramgen_curve:P-256",
      "-nodes",
      "-subj",
      "/CN=#{hostname}",
      "-keyout",
      keyfile,
      "-out",
      csr
    ])

    File.write!(
      extensions,
      "subjectAltName=DNS:#{hostname}\nbasicConstraints=critical,CA:FALSE\nextendedKeyUsage=serverAuth,clientAuth\n"
    )

    run!([
      "x509",
      "-req",
      "-in",
      csr,
      "-CA",
      cafile,
      "-CAkey",
      cakey,
      "-set_serial",
      "1",
      "-days",
      "1",
      "-extfile",
      extensions,
      "-out",
      certfile
    ])

    for path <- [certfile, keyfile, cafile, cakey, csr, extensions], do: File.chmod!(path, 0o600)
    [{:Certificate, der, _}] = :public_key.pem_decode(File.read!(certfile))
    %{certfile: certfile, keyfile: keyfile, cafile: cafile, der: der}
  end

  @doc """
  A self-signed client or server certificate, as the standard Incus client
  generates for itself, valid for two days. Expiry tests inject a clock.
  """
  def self_signed(root, name, hostname \\ nil) do
    certfile = Path.join(root, name <> ".pem")
    keyfile = Path.join(root, name <> ".key")

    san = if hostname, do: ["-addext", "subjectAltName=DNS:#{hostname}"], else: []

    run!(
      [
        "req",
        "-x509",
        "-newkey",
        "ec",
        "-pkeyopt",
        "ec_paramgen_curve:P-384",
        "-nodes",
        "-days",
        "2",
        "-subj",
        "/CN=#{hostname || name}"
      ] ++ san ++ ["-keyout", keyfile, "-out", certfile]
    )

    for path <- [certfile, keyfile], do: File.chmod!(path, 0o600)
    pem = File.read!(certfile)
    [{:Certificate, der, _}] = :public_key.pem_decode(pem)
    %{certfile: certfile, keyfile: keyfile, pem: pem, der: der}
  end

  # An EC key and certificate that spell out the curve's parameters instead of
  # naming it, as macOS's LibreSSL `req -newkey ec` writes them.
  def explicit_curve(root, name, hostname) do
    certfile = Path.join(root, name <> ".pem")
    keyfile = Path.join(root, name <> ".key")

    run!(~w(ecparam -name secp384r1 -param_enc explicit -genkey -noout -out) ++ [keyfile])

    run!(
      ~w(req -x509 -new -sha384 -days 2) ++
        ["-key", keyfile, "-subj", "/CN=#{hostname}", "-addext", "subjectAltName=DNS:#{hostname}"] ++
        ["-out", certfile]
    )

    for path <- [certfile, keyfile], do: File.chmod!(path, 0o600)
    pem = File.read!(certfile)
    [{:Certificate, der, _}] = :public_key.pem_decode(pem)
    %{certfile: certfile, keyfile: keyfile, pem: pem, der: der}
  end

  defp run!(args) do
    {output, status} = System.cmd("openssl", args, stderr_to_stdout: true)
    if status != 0, do: raise("fixture certificate generation failed: #{output}")
  end
end

defmodule Macus.TestSupport.InvalidHeaderHandler do
  @moduledoc false
  @behaviour :cowboy_handler

  @impl true
  def init(req, state) do
    :cowboy_req.cast(
      {:switch_protocol, %{"upgrade" => "sftp\r\nx-injected: yes"},
       Macus.TestSupport.CowboyTunnel, %{}},
      req
    )

    {:ok, req, state}
  end
end
