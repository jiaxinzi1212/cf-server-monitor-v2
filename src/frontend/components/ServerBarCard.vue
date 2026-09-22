<template>
  <router-link :to="to" class="server-card" :data-region="regionCode">
    <div class="server-card-header">
      <div class="server-identity">
        <span v-if="regionCode && regionCode !== 'xx'" class="country-os-icons">
          <img class="flag-img" :src="getPublicAssetUrl('flags/' + regionCode + '.svg')" :alt="regionCode">
          <OsIcon :os="server.os" />
        </span>
        <span v-else class="country-os-icons">
          <span class="flag-fallback">🏳️</span>
          <OsIcon :os="server.os" />
        </span>
        <span class="server-name">{{ server.name }}</span>
      </div>
      <span class="status-label" :style="{ color: statusColor, borderColor: statusColor }">{{ statusText }}</span>
    </div>
    <div class="server-meta">
      <div class="card-meta">
        <div v-if="sysConfig.show_price && priceText" class="card-meta-item">💰 {{ priceText }}</div>
        <div v-if="sysConfig.show_expire && server.expire_date" class="card-meta-item card-meta-expire">
          📅 <span :class="{ 'expired': isExpired }">{{ expireText }}</span>
          <span v-if="expireDateTitle" class="card-meta-tooltip">{{ expireDateTitle }}</span>
        </div>
      </div>
      <div class="card-badges">
        <span v-for="(tag, index) in tagList" :key="tag" :class="['badge', 'badge-tag', tagColorClass(index)]">{{ tag }}</span>
        <span v-if="hasPublicIPv4 && hasPublicIPv6" class="badge badge-v4-v6">IPv4/6</span>
        <template v-else>
          <span v-if="hasPublicIPv4" class="badge badge-v4">IPv4</span>
          <span v-if="hasPublicIPv6" class="badge badge-v6">IPv6</span>
        </template>
      </div>
    </div>
    <div class="server-stats">
      <div class="stat-row">
        <span class="stat-key">CPU</span>
        <div class="stat-content stat-content-meter">
          <div class="stat-bar-container">
            <div class="stat-bar-fill" :style="{ width: cpuPercent + '%', background: getUsageColor(cpuPercent) }"></div>
          </div>
          <span class="stat-value">{{ cpuPercent.toFixed(2) }}%</span>
        </div>
      </div>
      <div class="stat-row">
        <span class="stat-key">RAM</span>
        <div class="stat-content stat-content-meter">
          <div class="stat-bar-container">
            <div class="stat-bar-fill" :style="{ width: ramPercent + '%', background: getUsageColor(ramPercent) }"></div>
          </div>
          <span class="stat-value">{{ ramPercent.toFixed(2) }}%</span>
        </div>
      </div>
      <div class="stat-row">
        <span class="stat-key">DISK</span>
        <div class="stat-content stat-content-meter">
          <div class="stat-bar-container">
            <div class="stat-bar-fill" :style="{ width: diskPercent + '%', background: getUsageColor(diskPercent) }"></div>
          </div>
          <span class="stat-value">{{ diskPercent.toFixed(2) }}%</span>
        </div>
      </div>
      <div class="stat-row" v-if="sysConfig.show_tf">
        <span class="stat-key">USE</span>
        <div class="stat-content stat-content-meter">
          <template v-if="server.traffic_limit">
            <div class="stat-bar-container">
              <div class="stat-bar-fill" :style="{ width: Math.min(100, trafficUsagePercent) + '%', background: getUsageColor(trafficUsagePercent) }"></div>
            </div>
            <span class="stat-value">{{ trafficUsagePercentText }}%</span>
          </template>
          <template v-else>
            <div class="stat-bar-container">
              <div class="stat-bar-fill" style="background-image: linear-gradient(to right, #00d4aa, #4da6ff, #ffb870, #f85149);"></div>
            </div>
            <span class="stat-value" style="font-size: 2em;line-height: 0;">∞</span>
          </template>
        </div>
      </div>
      <div class="stat-row">
        <span class="stat-key">LOAD</span>
        <div class="stat-content">
          <span class="net-down">{{ loadAvg[0].toFixed(2) }}</span>
          <span>{{ loadAvg[1].toFixed(2) }}</span>
          <span class="net-up">{{ loadAvg[2].toFixed(2) }}</span>
        </div>
      </div>
      <div class="stat-row">
        <span class="stat-key">NET</span>
        <div class="stat-content">
          <span class="net-down">▼ {{ netInSpeed }}/s</span>
          <span class="net-up">▲ {{ netOutSpeed }}/s</span>
        </div>
      </div>
      <div class="stat-row">
        <span class="stat-key">TRF</span>
        <div class="stat-content">
          <span class="net-down">▼ {{ totalRxMonthly }}</span>
          <span class="net-up">▲ {{ totalTxMonthly }}</span>
          <span v-if="sysConfig.show_tf && server.traffic_limit" class="stat-limit">/ 📦 {{ formatBytes(server.traffic_limit * 1024 * 1024 * 1024) }}</span>
        </div>
      </div>
    </div>
    <div class="server-space"></div>
    <ServerLatencyPanel
      :show-three-net-details="sysConfig.show_three_net_details"
      :has-three-net-details="hasThreeNetDetails"
      :three-net-details="threeNetDetails"
      :has-ping-data="hasPingData"
      :ping-list="pingList"
      :timeout-text="trans.timeout"
      :get-ping-color="getPingColor"
      :get-loss-color="getLossColor"
      :format-ping-value="formatPingValue"
      :format-loss-value="formatLossValue"
      :is-ping-valid="isPingValid"
    />
    <div v-if="server.nq_url" class="nq-report-row">
      <span
        class="nq-report-link"
        role="link"
        tabindex="0"
        :title="nodeQualityTitle"
        @click.stop.prevent="openNodeQuality"
        @keydown.enter.stop.prevent="openNodeQuality"
        @keydown.space.stop.prevent="openNodeQuality"
      >
        <span class="nq-report-mark">N</span>
        <span>NQ</span>
      </span>
    </div>
  </router-link>
</template>

<script setup>
import { computed } from 'vue'
import OsIcon from './OsIcon.vue'
import ServerLatencyPanel from './ServerLatencyPanel.vue'
import { DEFAULT_SERVER_CARD_CONFIG, useServerCardData } from '../composables/useServerCardData'

const props = defineProps({
  server: {
    type: Object,
    required: true
  },
  sysConfig: {
    type: Object,
    default: () => ({ ...DEFAULT_SERVER_CARD_CONFIG })
  },
  to: {
    type: String,
    default: ''
  }
})

const nodeQualityTitle = computed(() => {
  const timestamp = Number(props.server?.nq_updated_at || 0)
  if (!timestamp) return '打开最新 NodeQuality 报告'
  return `NodeQuality · ${new Date(timestamp).toLocaleString()}`
})

function openNodeQuality() {
  const url = String(props.server?.nq_url || '')
  if (!/^https:\/\/(?:www\.)?nodequality\.com\/r\//i.test(url)) return
  window.open(url, '_blank', 'noopener,noreferrer')
}

const {
  trans,
  regionCode,
  statusColor,
  statusText,
  cpuPercent,
  ramPercent,
  diskPercent,
  trafficUsagePercent,
  trafficUsagePercentText,
  getUsageColor,
  tagList,
  tagColorClass,
  hasPublicIPv4,
  hasPublicIPv6,
  netInSpeed,
  netOutSpeed,
  totalRxMonthly,
  totalTxMonthly,
  priceText,
  expireDateTitle,
  loadAvg,
  isExpired,
  expireText,
  isPingValid,
  getPingColor,
  getLossColor,
  formatPingValue,
  formatLossValue,
  pingList,
  hasPingData,
  threeNetDetails,
  hasThreeNetDetails,
  getPublicAssetUrl,
  formatBytes
} = useServerCardData(props)
</script>

<style scoped>
.nq-report-row {
  display: flex;
  align-items: center;
  margin-top: 8px;
}

.nq-report-link {
  display: inline-flex;
  align-items: center;
  gap: 5px;
  min-height: 24px;
  padding: 2px 8px 2px 5px;
  border: 1px solid rgba(16, 185, 129, 0.45);
  border-radius: 5px;
  background: rgba(16, 185, 129, 0.06);
  color: inherit;
  font-size: 12px;
  line-height: 1;
  cursor: pointer;
  user-select: none;
  transition: transform .15s ease, border-color .15s ease, background .15s ease;
}

.nq-report-link:hover,
.nq-report-link:focus-visible {
  border-color: rgba(16, 185, 129, 0.8);
  background: rgba(16, 185, 129, 0.13);
  transform: translateY(-1px);
  outline: none;
}

.nq-report-mark {
  display: inline-grid;
  place-items: center;
  width: 15px;
  height: 15px;
  border-radius: 3px;
  background: linear-gradient(135deg, #34d399, #0ea5e9);
  color: white;
  font-size: 9px;
  font-weight: 800;
}
</style>
