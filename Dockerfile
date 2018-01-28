FROM nervesproject/nerves:0.13.5
EXPOSE 4040 5000 27347
WORKDIR /tmp
RUN wget https://github.com/elixir-lang/elixir/releases/download/v1.6.0/Precompiled.zip && \
  unzip -d /usr/local/elixir Precompiled.zip && \
  rm /tmp/Precompiled.zip
ENV PATH /usr/local/elixir/bin:$PATH
WORKDIR /app
COPY . .
COPY config/host/auth_secret_template.exs config/host/auth_secret.exs
ENV MIX_ENV dev
RUN mix local.hex --force && \
  mix local.rebar --force && \
  mix archive.install hex nerves_bootstrap --force && \
  mix deps.get && \
  mix deps.compile
  # We will have to figure out how resin.io will communicate with attached arduino
  # mix compile
ENV FARMBOT_EMAIL admin@admin.com
ENV FARMBOT_PASSWORD admin
ENTRYPOINT ["mix", "run", "--no-halt"]

