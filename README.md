# POC: servidor MCP — WebFlux + `.block()` vs WebMVC + Virtual Threads

Compara dos modelos de ejecución para una tool MCP que hace I/O bloqueante contra un backend lento.

| Módulo | Stack | Cliente HTTP | Dónde corre la tool |
|---|---|---|---|
| `mcp-webflux-block` | `spring-ai-starter-mcp-server-webflux`, `type: SYNC` | `WebClient` + `.block()` | `boundedElastic` (platform threads, máx. 10 × CPUs = 20) |
| `mcp-mvc-vt` | `spring-ai-starter-mcp-server-webmvc`, `type: SYNC`, `spring.threads.virtual.enabled=true` | `RestClient` (JDK HttpClient) | virtual thread del request de Tomcat |

Stack: Java 21, Spring Boot 4.1.2, Spring AI 2.0.2, transporte MCP Streamable HTTP (`POST /mcp`).
Config por defecto: `type: SYNC`, `protocol: STATELESS`,
`streamable-http.keep-alive-interval: 30s`. Con `MCP_PROTOCOL=STREAMABLE` se usa el modo con sesión
(`Mcp-Session-Id`). En ambos modos la tool corre en el mismo thread (ver abajo).
Ambas apps exponen Actuator `health`, `metrics` y `prometheus`, y la tool `getBalance(accountId)` loguea
`Thread.currentThread()` y si es virtual.

Todos los datos y endpoints son ficticios.

## Estructura

```
mcp-webflux-block/       app 1 (WebFlux + block)
mcp-mvc-vt/              app 2 (MVC + virtual threads)
wiremock/mappings/       GET /accounts/{id}/balance con delay (500 ms por defecto)
k6/mcp-load.js           handshake MCP por VU + tools/call en bucle, rampa 10 → 500 VUs
scripts/smoke-test.sh    verifica initialize → initialized → tools/call contra cada app
scripts/run-benchmark.sh corre la carga contra cada app por separado y genera results/comparison-<protocolo>-*.md y results/<app>-<protocolo>.{k6.json,summary.json}
docker-compose.yml       wiremock + 2 apps (2 CPUs / 1 GB cada una) + k6 (perfil loadtest)
```

## Uso

Requisitos: Docker (con Compose v2) y bash (en Windows, Git Bash). No hace falta k6 ni JDK local:
las imágenes se compilan en Docker y k6 corre como contenedor.

```bash
# Levantar todo y verificar que ambas apps responden por MCP
docker compose up -d --build --wait
scripts/smoke-test.sh                 # usa http://localhost:8081 y http://localhost:8082

# Ver en qué thread corre la tool
docker compose logs mcp-webflux-block mcp-mvc-vt | grep getBalance

# Benchmark completo (una app a la vez) → results/comparison-<protocolo>-<timestamp>.md
scripts/run-benchmark.sh
```

Parámetros del benchmark (variables de entorno):

| Variable | Default | Descripción |
|---|---|---|
| `MCP_PROTOCOL` | `STATELESS` | `STATELESS` o `STREAMABLE` |
| `BACKEND_DELAY_MS` | `500` | delay de WireMock (se aplica vía admin API, sin reiniciar) |
| `START_VUS` / `MAX_VUS` | `10` / `500` | rampa de VUs |
| `RAMP_UP` / `HOLD` / `RAMP_DOWN` | `2m` / `1m` / `20s` | duración de etapas |
| `REQ_TIMEOUT` | `30s` | timeout por request en k6 (los que lo superan cuentan como error) |
| `TOOL_LOG_LEVEL` | `INFO` | `WARN` silencia el log por llamada |
| `APPS` | ambas | p.ej. `APPS=mcp-mvc-vt` |

Ejemplo de corrida corta: `MAX_VUS=50 RAMP_UP=15s HOLD=5s scripts/run-benchmark.sh`

Puertos: `8081` webflux, `8082` mvc-vt, `8089` WireMock. Métricas: `/actuator/prometheus`.

Compilación local (opcional): `mvn package` con `JAVA_HOME` apuntando a un JDK 21.

## Métricas del reporte

Se calculan solo sobre `tools/call` (el handshake se reporta aparte):

- **req/s**: `tool_calls` / duración total del test.
- **p50 / p95 / p99**: latencia de `tools/call` vista por k6.
- **% errores**: HTTP ≠ 200, timeout, JSON-RPC sin `result` o `isError: true`.
- **% errores handshake**: fallos en `initialize` / `notifications/initialized`.

Con 500 ms de backend y sin think time, el máximo teórico es `VUs / 0,5 s` (1000 req/s con 500 VUs).

## Decisiones para que la comparación sea justa

- El pool de Reactor Netty por defecto se limita a `max(CPUs, 8) × 2` conexiones; se sube a 1000 para que
  el cuello de botella no sea el cliente HTTP sino el modelo de ejecución.
- WireMock corre con respuestas asíncronas y 1000 threads de contenedor para no ser él el límite.
- Cada app se prueba sola (la otra está detenida) y en un contenedor recién creado.

## Por qué WebFlux + SYNC se satura

Con `type: SYNC` sobre WebFlux, Spring AI ejecuta las tools síncronas en `Schedulers.boundedElastic()`,
cuyo tope es `10 × CPUs` threads (20 con 2 CPUs). Cada `.block()` ocupa uno durante los 500 ms del backend,
así que el throughput se estanca en ~`20 / 0,5 s = 40 req/s` y el resto de requests espera en la cola,
lo que dispara la latencia. Con virtual threads cada request bloquea su propio thread virtual y el carrier
se libera, así que el throughput escala con los VUs hasta que CPU o backend sean el límite.
