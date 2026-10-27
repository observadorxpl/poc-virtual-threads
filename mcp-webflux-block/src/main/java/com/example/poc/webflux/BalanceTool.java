package com.example.poc.webflux;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.ai.tool.annotation.Tool;
import org.springframework.ai.tool.annotation.ToolParam;
import org.springframework.stereotype.Service;
import org.springframework.web.reactive.function.client.WebClient;

@Service
public class BalanceTool {

    private static final Logger log = LoggerFactory.getLogger(BalanceTool.class);

    private final WebClient backendWebClient;

    public BalanceTool(WebClient backendWebClient) {
        this.backendWebClient = backendWebClient;
    }

    @Tool(name = "getBalance", description = "Returns the current balance of a fictitious bank account")
    public AccountBalance getBalance(@ToolParam(description = "Account identifier, e.g. ACC-0001") String accountId) {
        Thread current = Thread.currentThread();
        log.info("getBalance accountId={} thread={} virtual={}", accountId, current, current.isVirtual());
        return backendWebClient.get()
                .uri("/accounts/{id}/balance", accountId)
                .retrieve()
                .bodyToMono(AccountBalance.class)
                .block();
    }

    public record AccountBalance(String accountId, double balance, String currency, String asOf) {
    }
}
