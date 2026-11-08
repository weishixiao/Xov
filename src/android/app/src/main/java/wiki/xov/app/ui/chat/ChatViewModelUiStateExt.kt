package wiki.xov.app.ui.chat

// [T-android-split-chat] Small UI-state toggle methods extracted from
// ChatViewModel as extension functions (verbatim): tool-detail sheet,
// browser sheet, memory sheet, attachment list. The 4 backing state fields
// were flipped private->internal. No logic change.

import android.content.Context
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.net.Uri
import android.util.Log
import androidx.lifecycle.ViewModel
import androidx.lifecycle.ViewModelProvider
import androidx.lifecycle.viewModelScope
import androidx.compose.foundation.lazy.LazyListState
import wiki.xov.app.agent.Level
import wiki.xov.app.agent.ToolLoopDetector
import wiki.xov.app.browser.BrowserActionInput
import wiki.xov.app.browser.BrowserTabPool
import wiki.xov.app.data.db.MessageEntity
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.Compress
import androidx.compose.material.icons.filled.Delete
import androidx.compose.material.icons.filled.Lightbulb
import androidx.compose.material.icons.filled.Psychology
import androidx.compose.material.icons.outlined.Build
import androidx.compose.material.icons.outlined.Extension
import wiki.xov.app.data.BPETokenizer
import wiki.xov.app.data.ContextOffload
import wiki.xov.app.data.ContextPolicy
import wiki.xov.app.logging.AppLogger
import wiki.xov.app.data.FileMentionIndex
import wiki.xov.app.data.db.CompactMarkerEntity
import wiki.xov.app.data.model.AgentContentPart
import wiki.xov.app.data.model.AgentToolDefinition
import wiki.xov.app.data.model.LLMMessage
import wiki.xov.app.data.model.LLMModel
import wiki.xov.app.data.model.LLMStreamChunk
import wiki.xov.app.data.model.LLMUsage
import wiki.xov.app.data.model.ModelGroup
import wiki.xov.app.data.model.ThinkingLevel
import wiki.xov.app.R
import wiki.xov.app.data.repository.ChatRepository
import wiki.xov.app.data.repository.MemoryRepository
import wiki.xov.app.data.repository.ProviderRepository
import wiki.xov.app.provider.ImageBudget
import wiki.xov.app.provider.LLMProvider
import wiki.xov.app.provider.ProviderFactory
import wiki.xov.app.sandbox.ExecutionCoordinator
import wiki.xov.app.terminal.MinisOpenUrlBroker
import wiki.xov.app.terminal.MinisUrlMarker
import wiki.xov.app.tools.AgentTools
import wiki.xov.app.tools.FileEditTool
import wiki.xov.app.tools.FileReadTool
import wiki.xov.app.tools.FileWriteTool
import wiki.xov.app.tools.MemoryTools
import wiki.xov.app.tools.ReadImageTool
import wiki.xov.app.tools.ToolExecutionResult
import wiki.xov.app.offload.OffloadPermissionManager
import wiki.xov.app.service.SessionActivityTracker
import wiki.xov.app.service.SessionConcurrencyManager
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.flow.MutableSharedFlow
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.SharedFlow
import kotlinx.coroutines.flow.SharingStarted
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asSharedFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.coroutines.flow.combine
import kotlinx.coroutines.flow.first
import kotlinx.coroutines.flow.stateIn
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import kotlinx.coroutines.yield
import org.json.JSONObject
import java.io.ByteArrayOutputStream

internal fun ChatViewModel.openToolDetail(toolBlockId: String) {
    _selectedToolDetailId.value = toolBlockId
}

internal fun ChatViewModel.closeToolDetail() {
    _selectedToolDetailId.value = null
}

internal fun ChatViewModel.toggleBrowserSheet() {
    val opening = !_showBrowserSheet.value
    if (opening) browserTabPool.ensureTabForUI()
    _showBrowserSheet.value = opening
}

internal fun ChatViewModel.dismissBrowserSheet() {
    _showBrowserSheet.value = false
}

/**
 * Open the session browser sheet, focused on the tab whose URL matches
 * [url]. If no pool tab currently has that URL, a new tab is created and
 * loaded. Used by the tool-call preview's globe button so the agent's
 * existing browser_use page is reused when available instead of spawning
 * a duplicate tab.
 */
internal fun ChatViewModel.openBrowserSheetForUrl(url: String) {
    if (url.isBlank()) {
        browserTabPool.ensureTabForUI()
    } else {
        browserTabPool.selectOrCreateTabForURL(url)
    }
    _showBrowserSheet.value = true
}

internal fun ChatViewModel.toggleMemorySheet() {
    _showMemorySheet.value = !_showMemorySheet.value
}

internal fun ChatViewModel.dismissMemorySheet() {
    _showMemorySheet.value = false
}

internal fun ChatViewModel.addAttachment(attachment: InputAttachment) {
    _attachments.value = _attachments.value + attachment
}

internal fun ChatViewModel.removeAttachment(id: String) {
    _attachments.value = _attachments.value.filter { it.id != id }
}

internal fun ChatViewModel.clearAttachments() {
    _attachments.value = emptyList()
}
