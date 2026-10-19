defmodule MqttX.Test.TLSFixtures do
  @moduledoc """
  Generates the TLS fixtures the TLS and wss tests use — a private CA and a
  server certificate for the DNS name `localhost` only, signed by it — into
  `test/fixtures/tls` when the suite starts. Nothing is committed: a private
  key in the repository is a private key in the repository, however
  harmless, and secret scanners rightly say so.

  Files: `ca.pem`, `server.pem`, `server-key.pem` (EC P-256 throughout). The
  certificate names ONLY `localhost`, so connecting to 127.0.0.1 must fail the
  hostname check. The CA key is not written: nothing else is ever signed by
  it, and no real system trusts it.
  """

  require Record

  @hrl "public_key/include/public_key.hrl"

  Record.defrecordp(:tbs, :OTPTBSCertificate, Record.extract(:OTPTBSCertificate, from_lib: @hrl))

  Record.defrecordp(
    :spki,
    :OTPSubjectPublicKeyInfo,
    Record.extract(:OTPSubjectPublicKeyInfo, from_lib: @hrl)
  )

  Record.defrecordp(
    :pk_alg,
    :PublicKeyAlgorithm,
    Record.extract(:PublicKeyAlgorithm, from_lib: @hrl)
  )

  Record.defrecordp(
    :sig_alg,
    :SignatureAlgorithm,
    Record.extract(:SignatureAlgorithm, from_lib: @hrl)
  )

  Record.defrecordp(:validity, :Validity, Record.extract(:Validity, from_lib: @hrl))
  Record.defrecordp(:extension, :Extension, Record.extract(:Extension, from_lib: @hrl))

  Record.defrecordp(
    :attr,
    :AttributeTypeAndValue,
    Record.extract(:AttributeTypeAndValue, from_lib: @hrl)
  )

  Record.defrecordp(
    :basic_constraints,
    :BasicConstraints,
    Record.extract(:BasicConstraints, from_lib: @hrl)
  )

  Record.defrecordp(:ec_private_key, :ECPrivateKey, Record.extract(:ECPrivateKey, from_lib: @hrl))
  Record.defrecordp(:ec_point, :ECPoint, Record.extract(:ECPoint, from_lib: @hrl))

  @secp256r1 {1, 2, 840, 10045, 3, 1, 7}
  @id_ec_public_key {1, 2, 840, 10045, 2, 1}
  @ecdsa_with_sha256 {1, 2, 840, 10045, 4, 3, 2}
  @id_at_common_name {2, 5, 4, 3}
  @id_ce_basic_constraints {2, 5, 29, 19}
  @id_ce_key_usage {2, 5, 29, 15}
  @id_ce_ext_key_usage {2, 5, 29, 37}
  @id_ce_subject_alt_name {2, 5, 29, 17}
  @id_kp_server_auth {1, 3, 6, 1, 5, 5, 7, 3, 1}

  @century 100 * 365 * 86_400

  @doc "Write fresh fixtures into `dir`, replacing any already there."
  @spec generate!(Path.t()) :: :ok
  def generate!(dir) do
    File.mkdir_p!(dir)

    ca_key = :public_key.generate_key({:namedCurve, @secp256r1})
    ca_name = name("MqttX Test CA")
    ca_der = :public_key.pkix_sign(tbs_for(ca_name, ca_name, ca_key, ca_extensions()), ca_key)

    server_key = :public_key.generate_key({:namedCurve, @secp256r1})
    server_tbs = tbs_for(name("localhost"), ca_name, server_key, server_extensions())
    server_der = :public_key.pkix_sign(server_tbs, ca_key)

    File.write!(Path.join(dir, "ca.pem"), pem_cert(ca_der))
    File.write!(Path.join(dir, "server.pem"), pem_cert(server_der))

    File.write!(
      Path.join(dir, "server-key.pem"),
      :public_key.pem_encode([:public_key.pem_entry_encode(:ECPrivateKey, server_key)])
    )

    :ok
  end

  defp tbs_for(subject, issuer, key, extensions) do
    <<serial::120>> = :crypto.strong_rand_bytes(15)

    tbs(
      version: :v3,
      serialNumber: serial + 1,
      signature: sig_alg(algorithm: @ecdsa_with_sha256, parameters: :asn1_NOVALUE),
      issuer: issuer,
      validity: validity(notBefore: time(-86_400), notAfter: time(@century)),
      subject: subject,
      subjectPublicKeyInfo:
        spki(
          algorithm: pk_alg(algorithm: @id_ec_public_key, parameters: {:namedCurve, @secp256r1}),
          subjectPublicKey: ec_point(point: ec_private_key(key, :publicKey))
        ),
      issuerUniqueID: :asn1_NOVALUE,
      subjectUniqueID: :asn1_NOVALUE,
      extensions: extensions
    )
  end

  defp name(common_name) do
    {:rdnSequence, [[attr(type: @id_at_common_name, value: {:utf8String, common_name})]]}
  end

  defp ca_extensions do
    [
      extension(
        extnID: @id_ce_basic_constraints,
        critical: true,
        extnValue: basic_constraints(cA: true, pathLenConstraint: :asn1_NOVALUE)
      ),
      extension(extnID: @id_ce_key_usage, critical: true, extnValue: [:keyCertSign, :cRLSign])
    ]
  end

  defp server_extensions do
    [
      extension(
        extnID: @id_ce_basic_constraints,
        critical: false,
        extnValue: basic_constraints(cA: false, pathLenConstraint: :asn1_NOVALUE)
      ),
      extension(
        extnID: @id_ce_key_usage,
        critical: true,
        extnValue: [:digitalSignature, :keyAgreement]
      ),
      extension(extnID: @id_ce_ext_key_usage, critical: false, extnValue: [@id_kp_server_auth]),
      extension(
        extnID: @id_ce_subject_alt_name,
        critical: false,
        extnValue: [dNSName: ~c"localhost"]
      )
    ]
  end

  # X.509 writes years before 2050 as UTCTime and later ones as GeneralizedTime
  defp time(offset_seconds) do
    dt = DateTime.add(DateTime.utc_now(), offset_seconds, :second)

    if dt.year < 2050,
      do: {:utcTime, String.to_charlist(Calendar.strftime(dt, "%y%m%d%H%M%SZ"))},
      else: {:generalTime, String.to_charlist(Calendar.strftime(dt, "%Y%m%d%H%M%SZ"))}
  end

  defp pem_cert(der), do: :public_key.pem_encode([{:Certificate, der, :not_encrypted}])
end
