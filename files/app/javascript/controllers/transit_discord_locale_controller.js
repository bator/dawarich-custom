import { Controller } from "@hotwired/stimulus"

// /transit/discord: the preview shows the message in the language picked in
// the dropdown before it is saved. The page renders one preview per language
// (Gtfs::Discord::Texts::LOCALES); this only shows the matching one.
export default class extends Controller {
  static targets = ["preview"]

  switch(event) {
    for (const preview of this.previewTargets) {
      preview.hidden = preview.dataset.locale !== event.target.value
    }
  }
}
