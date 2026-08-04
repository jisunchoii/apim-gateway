# APIM classic Premium autoscale. 유닛 변경 작업 자체가 15분 이상 걸리므로 순간 burst는
# 429와 Retry-After로 흡수하고, 지속적인 부하 변화에만 반응하도록 cooldown을 길게 둔다.
# Capacity 메트릭은 Workbook의 APIM capacity 차트와 같은 지표다.
resource "azurerm_monitor_autoscale_setting" "apim" {
  name                = "autoscale-${local.apim_name}"
  resource_group_name = azurerm_resource_group.rg.name
  location            = var.location
  target_resource_id  = azurerm_api_management.apim.id
  tags                = local.tags

  profile {
    name = "capacity-driven"

    capacity {
      default = 1
      minimum = 1
      maximum = 3
    }

    # 지속적인 부하 상승에만 반응한다. 짧은 창은 streaming long-tail 요청의
    # 일시적 CPU spike로 불필요한 증설이 나가는 것을 막는다.
    rule {
      metric_trigger {
        metric_name        = "Capacity"
        metric_resource_id = azurerm_api_management.apim.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT5M"
        time_aggregation   = "Average"
        operator           = "GreaterThan"
        threshold          = 50
      }

      scale_action {
        direction = "Increase"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT20M"
      }
    }

    rule {
      metric_trigger {
        metric_name        = "Capacity"
        metric_resource_id = azurerm_api_management.apim.id
        time_grain         = "PT1M"
        statistic          = "Average"
        time_window        = "PT60M"
        time_aggregation   = "Average"
        operator           = "LessThan"
        threshold          = 30
      }

      scale_action {
        direction = "Decrease"
        type      = "ChangeCount"
        value     = "1"
        cooldown  = "PT60M"
      }
    }
  }
}
