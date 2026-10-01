<template>
  <!-- WE Sign: the mark of the selected brand pack, named by the page (app/views/shared/_meta.html.erb) -->
  <img
    :src="mark.content"
    :alt="mark.dataset.alt"
    class="brand-logo"
    style="height: 28px; width: auto"
  >
</template>

<script>
export default {
  name: 'ProjectLogo',
  computed: {
    mark () {
      return document.querySelector('meta[name="brand-mark"]')
    }
  }
}
</script>
