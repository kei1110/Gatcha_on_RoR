// app/javascript/controllers/leave_request_form_controller.js
import { Controller } from "@hotwired/stimulus"

// 申請フォームのリアルタイム見積り（Phase 2-2a 設計 §4.2・D3 サーバ往復）。
// 生 fetch+innerHTML はしない — Turbo Frame の src を debounce で書き換え、Turbo が自動取得・差し替え。
export default class extends Controller {
  static targets = ["leaveType", "startDate", "endDate", "halfDay", "estimate", "reason"]
  static values = { previewUrl: String }

  refresh() {
    clearTimeout(this.timer)
    this.timer = setTimeout(() => this.updateFrameSrc(), 300)
  }

  updateFrameSrc() {
    if (!this.startDateTarget.value || !this.endDateTarget.value || !this.leaveTypeTarget.value) return
    const p = new URLSearchParams({
      leave_type_id: this.leaveTypeTarget.value,
      start_date: this.startDateTarget.value,
      end_date: this.endDateTarget.value,
      half_day_type: this.halfDayTarget.value,
    })
    this.estimateTarget.src = `${this.previewUrlValue}?${p.toString()}`
  }

  applyTemplate(event) {
    const text = event.currentTarget.dataset.template
    this.reasonTarget.value = this.reasonTarget.value ? `${this.reasonTarget.value}\n${text}` : text
  }
}
