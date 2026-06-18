import { Controller } from "@hotwired/stimulus"

// 理由テンプレートチップ → textarea に追記（2-3・最小）
export default class extends Controller {
  static targets = ["reason"]

  apply(event) {
    const text = event.params.text
    const ta = this.reasonTarget
    ta.value = ta.value ? `${ta.value}\n${text}` : text
  }
}
