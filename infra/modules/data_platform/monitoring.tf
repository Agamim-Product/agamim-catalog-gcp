# Alerts: a refresh failed, or no refresh has succeeded for 90 minutes (the data is going stale).

resource "google_monitoring_alert_policy" "refresh_failed" {
  project      = var.project_id
  display_name = "Catalog refresh failed (${var.env})"
  combiner     = "OR"

  conditions {
    display_name = "A catalog-refresh-${var.env} execution failed"
    condition_threshold {
      filter          = "metric.type=\"workflows.googleapis.com/finished_execution_count\" AND resource.type=\"workflows.googleapis.com/Workflow\" AND resource.label.workflow_id=\"${google_workflows_workflow.refresh.name}\" AND metric.label.status=\"FAILED\""
      comparison      = "COMPARISON_GT"
      threshold_value = 0
      duration        = "0s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  documentation {
    content   = "Open Workflows > catalog-refresh-${var.env} > Executions to see which step failed. Gold keeps its last good state until the next successful run."
    mime_type = "text/markdown"
  }

  notification_channels = var.notification_channel_ids
}

resource "google_monitoring_alert_policy" "data_stale" {
  project      = var.project_id
  display_name = "Catalog data is stale (${var.env})"
  combiner     = "OR"
  enabled      = !var.schedule_paused

  conditions {
    display_name = "No successful catalog-refresh-${var.env} for 90 minutes"
    condition_absent {
      filter   = "metric.type=\"workflows.googleapis.com/finished_execution_count\" AND resource.type=\"workflows.googleapis.com/Workflow\" AND resource.label.workflow_id=\"${google_workflows_workflow.refresh.name}\" AND metric.label.status=\"SUCCEEDED\""
      duration = "5400s"
      aggregations {
        alignment_period   = "300s"
        per_series_aligner = "ALIGN_SUM"
      }
    }
  }

  notification_channels = var.notification_channel_ids
}
