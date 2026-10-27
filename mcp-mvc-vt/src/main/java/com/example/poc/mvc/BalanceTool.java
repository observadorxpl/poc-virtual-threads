package com.example.poc.mvc;

import org.slf4j.Logger;
import org.slf4j.LoggerFactory;
import org.springframework.ai.tool.annotation.Tool;
import org.springframework.ai.tool.annotation.ToolParam;
import org.springframework.stereotype.Service;
import org.springframework.web.client.RestClient;

@Service
public class BalanceTool {

    private static final Logger log = LoggerFactory.getLogger(BalanceTool.class);

    private final RestClient backendRestClient;

    public BalanceTool(RestClient backendRestClient) {
        this.backendRestClient = backendRestClient;
    }

    @Tool(name = "getBalance", description = "Returns the current balance of a fictitious bank account")
    public AccountBalance getBalance(@ToolParam(description = "Account identifier, e.g. ACC-0001") String accountId) {
        Thread current = Thread.currentThread();
        log.info("getBalance accountId={} thread={} virtual={}", accountId, current, current.isVirtual());
        return backendRestClient.get()
                .uri("/accounts/{id}/balance", accountId)
                .retrieve()
                .body(AccountBalance.class);
    }

    public record AccountBalance(String accountId, double balance, String currency, String asOf) {
    }
}
