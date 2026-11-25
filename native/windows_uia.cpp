#include <windows.h>
#include <ole2.h>
#include <uiautomation.h>

#include <atomic>
#include <charconv>
#include <climits>
#include <cstddef>
#include <cstdint>
#include <memory>
#include <new>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

// The UI Automation provider of one Cosmos window. The app describes what it draws as a flat list of
// nodes, which this file keeps a copy of and serves as one fragment per node under a fragment root for
// the window. Providers run with ProviderOptions_UseComThreading on the window's STA, so every call
// arrives on the UI thread and the tree needs no lock. What an assistive technology asks of a node goes
// back to Odin through the request callback, which only queues an event for the app.

namespace {

// Matches Access_Node in src/platform/platform.odin; Odin passes its slice as is.
struct Access_Node {
    uint64_t id;
    uint64_t parent;
    uint8_t role;
    const char *name;
    ptrdiff_t name_len;
    const char *value;
    ptrdiff_t value_len;
    float bounds[4];
    uint16_t states;
};
static_assert(sizeof(Access_Node) == 80);
static_assert(offsetof(Access_Node, role) == 16);
static_assert(offsetof(Access_Node, name) == 24);
static_assert(offsetof(Access_Node, value) == 40);
static_assert(offsetof(Access_Node, bounds) == 56);
static_assert(offsetof(Access_Node, states) == 72);

// Access_Role in src/platform/platform.odin, in its order.
enum Role : uint8_t {
    Role_Pane, Role_Group, Role_Text, Role_Image, Role_Button, Role_Check_Box, Role_Text_Field,
    Role_Combo_Box, Role_List, Role_List_Item, Role_Menu, Role_Menu_Item, Role_Dialog, Role_Status,
    Role_Count,
};

// Access_State bits in src/platform/platform.odin.
enum State_Bit : uint16_t {
    State_Disabled = 1 << 0,
    State_Focusable = 1 << 1,
    State_Checked = 1 << 2,
    State_Expanded = 1 << 3,
    State_Collapsed = 1 << 4,
    State_Selected = 1 << 5,
    State_Read_Only = 1 << 6,
};

// Access_Request in src/platform/access_windows.odin.
enum Request : int32_t { Request_Invoke, Request_Toggle, Request_Expand, Request_Collapse, Request_Focus };

using Request_Proc = void (*)(void *user, uint64_t id, int32_t request);

// A Status node is a notice; a dialog has no control type of its own, so it is a pane that says so.
constexpr CONTROLTYPEID CONTROL_TYPES[Role_Count] = {
    UIA_PaneControlTypeId, UIA_GroupControlTypeId, UIA_TextControlTypeId, UIA_ImageControlTypeId,
    UIA_ButtonControlTypeId, UIA_CheckBoxControlTypeId, UIA_EditControlTypeId, UIA_ComboBoxControlTypeId,
    UIA_ListControlTypeId, UIA_ListItemControlTypeId, UIA_MenuControlTypeId, UIA_MenuItemControlTypeId,
    UIA_PaneControlTypeId, UIA_TextControlTypeId,
};

struct Node {
    uint64_t id;
    uint64_t parent;
    Role role;
    uint16_t states;
    std::string name;
    std::string value;
    float bounds[4];
    int parent_index = -1;
    int first_child = -1;
    int last_child = -1;
    int next = -1;
    int previous = -1;
};

class Element;

// Shared by the window's state and every provider handed out, so a provider an assistive technology holds
// past the window still has something to read: a tree whose window is null answers nothing.
struct Tree {
    HWND window = nullptr;
    void *user = nullptr;
    Request_Proc request = nullptr;
    Element *root = nullptr;
    std::vector<Node> nodes;
    std::unordered_map<uint64_t, int> index;
    int first_child = -1;
    int last_child = -1;
    uint64_t focus = 0;

    const Node *find(uint64_t id) const {
        auto found = index.find(id);
        return found == index.end() ? nullptr : &nodes[found->second];
    }
};

bool has(int states, int bits) { return (states & bits) != 0; }

bool has_invoke(const Node &node) {
    return node.role == Role_Button ||
           (node.role == Role_Menu_Item && !has(node.states, State_Expanded | State_Collapsed));
}
bool has_toggle(const Node &node) { return node.role == Role_Check_Box; }
bool has_value(const Node &node) { return node.role == Role_Text_Field || node.role == Role_Combo_Box; }
bool has_expand_collapse(const Node &node) {
    return node.role == Role_Combo_Box ||
           (node.role == Role_Menu_Item && has(node.states, State_Expanded | State_Collapsed));
}
bool has_selection_item(const Node &node) { return node.role == Role_List_Item; }

ToggleState toggle_state(uint16_t states) {
    return has(states, State_Checked) ? ToggleState_On : ToggleState_Off;
}

ExpandCollapseState expand_state(const Node &node) {
    if (has(node.states, State_Expanded)) return ExpandCollapseState_Expanded;
    if (has(node.states, State_Collapsed) || node.role == Role_Combo_Box) {
        return ExpandCollapseState_Collapsed;
    }
    return ExpandCollapseState_LeafNode;
}

BSTR to_bstr(std::string_view text) {
    if (text.empty()) return SysAllocStringLen(L"", 0);
    int length = MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), nullptr, 0);
    if (length <= 0) return nullptr;
    BSTR result = SysAllocStringLen(nullptr, static_cast<UINT>(length));
    if (!result) return nullptr;
    MultiByteToWideChar(CP_UTF8, 0, text.data(), static_cast<int>(text.size()), result, length);
    return result;
}

HRESULT text_variant(std::string_view text, VARIANT *out) {
    out->bstrVal = to_bstr(text);
    if (!out->bstrVal) return E_OUTOFMEMORY;
    out->vt = VT_BSTR;
    return S_OK;
}

void bool_variant(bool on, VARIANT *out) {
    out->vt = VT_BOOL;
    out->boolVal = on ? VARIANT_TRUE : VARIANT_FALSE;
}

void int_variant(int value, VARIANT *out) {
    out->vt = VT_I4;
    out->lVal = value;
}

HRESULT last_error() { return HRESULT_FROM_WIN32(GetLastError()); }

class Element final : public IRawElementProviderSimple,
                      public IRawElementProviderFragment,
                      public IRawElementProviderFragmentRoot,
                      public IInvokeProvider,
                      public IToggleProvider,
                      public IValueProvider,
                      public IExpandCollapseProvider,
                      public ISelectionItemProvider {
public:
    Element(std::shared_ptr<Tree> tree, uint64_t id) noexcept : tree_(std::move(tree)), id_(id) {}

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID riid, void **out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        if (riid == __uuidof(IUnknown) || riid == __uuidof(IRawElementProviderSimple)) {
            *out = static_cast<IRawElementProviderSimple *>(this);
        } else if (riid == __uuidof(IRawElementProviderFragment)) {
            *out = static_cast<IRawElementProviderFragment *>(this);
        } else if (riid == __uuidof(IRawElementProviderFragmentRoot) && id_ == 0) {
            *out = static_cast<IRawElementProviderFragmentRoot *>(this);
        } else if (id_ == 0) {
            return E_NOINTERFACE;
        } else if (riid == __uuidof(IInvokeProvider)) {
            *out = static_cast<IInvokeProvider *>(this);
        } else if (riid == __uuidof(IToggleProvider)) {
            *out = static_cast<IToggleProvider *>(this);
        } else if (riid == __uuidof(IValueProvider)) {
            *out = static_cast<IValueProvider *>(this);
        } else if (riid == __uuidof(IExpandCollapseProvider)) {
            *out = static_cast<IExpandCollapseProvider *>(this);
        } else if (riid == __uuidof(ISelectionItemProvider)) {
            *out = static_cast<ISelectionItemProvider *>(this);
        } else {
            return E_NOINTERFACE;
        }
        AddRef();
        return S_OK;
    }
    ULONG STDMETHODCALLTYPE AddRef() override { return ++refs_; }
    ULONG STDMETHODCALLTYPE Release() override {
        ULONG count = --refs_;
        if (count == 0) delete this;
        return count;
    }

    // IRawElementProviderSimple

    HRESULT STDMETHODCALLTYPE get_ProviderOptions(ProviderOptions *out) override {
        if (!out) return E_POINTER;
        *out = static_cast<ProviderOptions>(ProviderOptions_ServerSideProvider |
                                            ProviderOptions_UseComThreading);
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE GetPatternProvider(PATTERNID pattern, IUnknown **out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        const Node *node;
        if (HRESULT result = find(&node); FAILED(result) || !node) return result;
        bool supported = false;
        switch (pattern) {
        case UIA_InvokePatternId: supported = has_invoke(*node); break;
        case UIA_TogglePatternId: supported = has_toggle(*node); break;
        case UIA_ValuePatternId: supported = has_value(*node); break;
        case UIA_ExpandCollapsePatternId: supported = has_expand_collapse(*node); break;
        case UIA_SelectionItemPatternId: supported = has_selection_item(*node); break;
        default: break;
        }
        if (supported) {
            *out = static_cast<IRawElementProviderSimple *>(this);
            AddRef();
        }
        return S_OK;
    }

    // The root reports nothing itself: the window's own host provider names it and gives its type.
    HRESULT STDMETHODCALLTYPE GetPropertyValue(PROPERTYID property, VARIANT *out) override {
        if (!out) return E_POINTER;
        VariantInit(out);
        const Node *node;
        if (HRESULT result = find(&node); FAILED(result) || !node) return result;
        switch (property) {
        case UIA_ControlTypePropertyId: int_variant(CONTROL_TYPES[node->role], out); break;
        case UIA_NamePropertyId:
            if (!node->name.empty()) return text_variant(node->name, out);
            break;
        case UIA_AutomationIdPropertyId: {
            char digits[20];
            auto written = std::to_chars(digits, digits + sizeof(digits), node->id);
            return text_variant(std::string_view(digits, static_cast<size_t>(written.ptr - digits)), out);
        }
        case UIA_IsEnabledPropertyId: bool_variant(!has(node->states, State_Disabled), out); break;
        case UIA_IsKeyboardFocusablePropertyId: bool_variant(has(node->states, State_Focusable), out); break;
        // Nothing in a window has keyboard focus while another window has it.
        case UIA_HasKeyboardFocusPropertyId:
            bool_variant(tree_->focus == id_ && ::GetFocus() == tree_->window, out);
            break;
        case UIA_IsOffscreenPropertyId: {
            bool offscreen;
            if (HRESULT result = is_offscreen(*node, &offscreen); FAILED(result)) return result;
            bool_variant(offscreen, out);
            break;
        }
        case UIA_IsDialogPropertyId:
            if (node->role == Role_Dialog) bool_variant(true, out);
            break;
        case UIA_LiveSettingPropertyId:
            if (node->role == Role_Status) int_variant(Polite, out);
            break;
        default: break;
        }
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE get_HostRawElementProvider(IRawElementProviderSimple **out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        if (id_ != 0) return S_OK;
        if (!tree_->window) return UIA_E_ELEMENTNOTAVAILABLE;
        return UiaHostProviderFromHwnd(tree_->window, out);
    }

    // IRawElementProviderFragment

    HRESULT STDMETHODCALLTYPE Navigate(NavigateDirection direction,
                                       IRawElementProviderFragment **out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        const Node *node;
        if (HRESULT result = find(&node); FAILED(result)) return result;
        const Tree &tree = *tree_;
        int target = -1;
        switch (direction) {
        case NavigateDirection_Parent:
            if (!node) return S_OK;
            if (node->parent_index < 0) return fragment_root(out);
            target = node->parent_index;
            break;
        case NavigateDirection_NextSibling: target = node ? node->next : -1; break;
        case NavigateDirection_PreviousSibling: target = node ? node->previous : -1; break;
        case NavigateDirection_FirstChild: target = node ? node->first_child : tree.first_child; break;
        case NavigateDirection_LastChild: target = node ? node->last_child : tree.last_child; break;
        default: return E_INVALIDARG;
        }
        if (target < 0) return S_OK;
        return element(tree.nodes[target].id, out);
    }

    // The window's host provider gives the root its runtime id.
    HRESULT STDMETHODCALLTYPE GetRuntimeId(SAFEARRAY **out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        const Node *node;
        if (HRESULT result = find(&node); FAILED(result) || !node) return result;
        SAFEARRAY *ids = SafeArrayCreateVector(VT_I4, 0, 3);
        if (!ids) return E_OUTOFMEMORY;
        int *data = static_cast<int *>(ids->pvData);
        data[0] = UiaAppendRuntimeId;
        data[1] = static_cast<int>(static_cast<uint32_t>(id_));
        data[2] = static_cast<int>(static_cast<uint32_t>(id_ >> 32));
        *out = ids;
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE get_BoundingRectangle(UiaRect *out) override {
        if (!out) return E_POINTER;
        *out = {};
        const Node *node;
        if (HRESULT result = find(&node); FAILED(result) || !node) return result;
        POINT origin{};
        if (!ClientToScreen(tree_->window, &origin)) return last_error();
        const float *b = node->bounds;
        *out = {static_cast<double>(origin.x) + b[0], static_cast<double>(origin.y) + b[1], b[2], b[3]};
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE GetEmbeddedFragmentRoots(SAFEARRAY **out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE SetFocus() override {
        const Node *node;
        if (HRESULT result = find(&node); FAILED(result) || !node) return result;
        if (has(node->states, State_Disabled)) return UIA_E_ELEMENTNOTENABLED;
        if (!has(node->states, State_Focusable)) return UIA_E_INVALIDOPERATION;
        tree_->request(tree_->user, id_, Request_Focus);
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE get_FragmentRoot(IRawElementProviderFragmentRoot **out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        if (!tree_->window || !tree_->root) return UIA_E_ELEMENTNOTAVAILABLE;
        *out = tree_->root;
        tree_->root->AddRef();
        return S_OK;
    }

    // IRawElementProviderFragmentRoot

    // The last node holding the point is the deepest or the one drawn over its earlier siblings.
    HRESULT STDMETHODCALLTYPE ElementProviderFromPoint(double x, double y,
                                                       IRawElementProviderFragment **out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        if (!tree_->window) return UIA_E_ELEMENTNOTAVAILABLE;
        POINT origin{};
        if (!ClientToScreen(tree_->window, &origin)) return last_error();
        double client_x = x - origin.x;
        double client_y = y - origin.y;
        const auto &nodes = tree_->nodes;
        for (auto node = nodes.rbegin(); node != nodes.rend(); ++node) {
            const float *b = node->bounds;
            if (client_x >= b[0] && client_y >= b[1] && client_x < b[0] + b[2] && client_y < b[1] + b[3]) {
                return element(node->id, out);
            }
        }
        *out = static_cast<IRawElementProviderFragment *>(this);
        AddRef();
        return S_OK;
    }

    HRESULT STDMETHODCALLTYPE GetFocus(IRawElementProviderFragment **out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        if (!tree_->window) return UIA_E_ELEMENTNOTAVAILABLE;
        if (tree_->focus == 0) return S_OK;
        return element(tree_->focus, out);
    }

    // IInvokeProvider

    HRESULT STDMETHODCALLTYPE Invoke() override { return act(has_invoke, Request_Invoke); }

    // IToggleProvider

    HRESULT STDMETHODCALLTYPE Toggle() override { return act(has_toggle, Request_Toggle); }
    HRESULT STDMETHODCALLTYPE get_ToggleState(ToggleState *out) override {
        if (!out) return E_POINTER;
        *out = ToggleState_Off;
        const Node *node;
        if (HRESULT result = pattern_node(has_toggle, &node); FAILED(result)) return result;
        *out = toggle_state(node->states);
        return S_OK;
    }

    // IValueProvider: the app owns text editing through its own keyboard handling, so a value set from
    // outside is refused rather than written behind the app's back.

    HRESULT STDMETHODCALLTYPE SetValue(LPCWSTR) override {
        const Node *node;
        if (HRESULT result = pattern_node(has_value, &node); FAILED(result)) return result;
        if (has(node->states, State_Disabled)) return UIA_E_ELEMENTNOTENABLED;
        return UIA_E_INVALIDOPERATION;
    }
    HRESULT STDMETHODCALLTYPE get_Value(BSTR *out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        const Node *node;
        if (HRESULT result = pattern_node(has_value, &node); FAILED(result)) return result;
        *out = to_bstr(node->value);
        return *out ? S_OK : E_OUTOFMEMORY;
    }
    HRESULT STDMETHODCALLTYPE get_IsReadOnly(BOOL *out) override {
        if (!out) return E_POINTER;
        *out = TRUE;
        const Node *node;
        if (HRESULT result = pattern_node(has_value, &node); FAILED(result)) return result;
        *out = has(node->states, State_Read_Only);
        return S_OK;
    }

    // IExpandCollapseProvider

    HRESULT STDMETHODCALLTYPE Expand() override { return act(has_expand_collapse, Request_Expand); }
    HRESULT STDMETHODCALLTYPE Collapse() override { return act(has_expand_collapse, Request_Collapse); }
    HRESULT STDMETHODCALLTYPE get_ExpandCollapseState(ExpandCollapseState *out) override {
        if (!out) return E_POINTER;
        *out = ExpandCollapseState_LeafNode;
        const Node *node;
        if (HRESULT result = pattern_node(has_expand_collapse, &node); FAILED(result)) return result;
        *out = expand_state(*node);
        return S_OK;
    }

    // ISelectionItemProvider: selecting an item picks it, as a click or Enter would, so Select reaches the
    // app as an invoke of the item. Lists hold one selection, so adding to or removing from it is refused.

    HRESULT STDMETHODCALLTYPE Select() override { return act(has_selection_item, Request_Invoke); }
    HRESULT STDMETHODCALLTYPE AddToSelection() override { return refuse_selection(); }
    HRESULT STDMETHODCALLTYPE RemoveFromSelection() override { return refuse_selection(); }
    HRESULT STDMETHODCALLTYPE get_IsSelected(BOOL *out) override {
        if (!out) return E_POINTER;
        *out = FALSE;
        const Node *node;
        if (HRESULT result = pattern_node(has_selection_item, &node); FAILED(result)) return result;
        *out = has(node->states, State_Selected);
        return S_OK;
    }
    HRESULT STDMETHODCALLTYPE get_SelectionContainer(IRawElementProviderSimple **out) override {
        if (!out) return E_POINTER;
        *out = nullptr;
        const Node *node;
        if (HRESULT result = pattern_node(has_selection_item, &node); FAILED(result)) return result;
        for (int at = node->parent_index; at >= 0; at = tree_->nodes[at].parent_index) {
            if (tree_->nodes[at].role != Role_List) continue;
            IRawElementProviderFragment *list;
            if (HRESULT result = element(tree_->nodes[at].id, &list); FAILED(result)) return result;
            *out = static_cast<Element *>(list);
            return S_OK;
        }
        return S_OK;
    }

private:
    ~Element() = default;

    // The node this provider stands for, or null for the root. A node the app no longer sets, or a window
    // that is gone, is not available.
    HRESULT find(const Node **out) const {
        *out = nullptr;
        if (!tree_->window) return UIA_E_ELEMENTNOTAVAILABLE;
        if (id_ == 0) return S_OK;
        *out = tree_->find(id_);
        return *out ? S_OK : UIA_E_ELEMENTNOTAVAILABLE;
    }

    HRESULT pattern_node(bool (*supports)(const Node &), const Node **out) const {
        if (HRESULT result = find(out); FAILED(result)) return result;
        return *out && supports(**out) ? S_OK : UIA_E_INVALIDOPERATION;
    }

    HRESULT act(bool (*supports)(const Node &), Request request) {
        const Node *node;
        if (HRESULT result = pattern_node(supports, &node); FAILED(result)) return result;
        if (has(node->states, State_Disabled)) return UIA_E_ELEMENTNOTENABLED;
        tree_->request(tree_->user, id_, request);
        return S_OK;
    }

    HRESULT refuse_selection() {
        const Node *node;
        if (HRESULT result = pattern_node(has_selection_item, &node); FAILED(result)) return result;
        return UIA_E_INVALIDOPERATION;
    }

    HRESULT element(uint64_t id, IRawElementProviderFragment **out) const {
        auto *made = new (std::nothrow) Element(tree_, id);
        if (!made) return E_OUTOFMEMORY;
        *out = made;
        return S_OK;
    }

    HRESULT fragment_root(IRawElementProviderFragment **out) const {
        if (!tree_->root) return UIA_E_ELEMENTNOTAVAILABLE;
        *out = tree_->root;
        tree_->root->AddRef();
        return S_OK;
    }

    // A node is offscreen when its window cannot be seen or it lies wholly outside the client area.
    HRESULT is_offscreen(const Node &node, bool *out) const {
        RECT client;
        if (!GetClientRect(tree_->window, &client)) return last_error();
        const float *b = node.bounds;
        *out = !IsWindowVisible(tree_->window) || IsIconic(tree_->window) || b[2] <= 0 || b[3] <= 0 ||
               b[0] >= client.right || b[1] >= client.bottom || b[0] + b[2] <= 0 || b[1] + b[3] <= 0;
        return S_OK;
    }

    std::atomic<ULONG> refs_{1};
    std::shared_ptr<Tree> tree_;
    uint64_t id_;
};

struct State {
    std::shared_ptr<Tree> tree;
    Element *root = nullptr;
    // A provider was handed to UI Automation, so destroying the window must take it back.
    bool served = false;
};

bool same_text(const std::string &held, const char *text, ptrdiff_t length) {
    return length >= 0 && held == std::string_view(text, static_cast<size_t>(length));
}

bool unchanged(const Tree &tree, const Access_Node *nodes, size_t count) {
    if (tree.nodes.size() != count) return false;
    for (size_t i = 0; i < count; ++i) {
        const Node &held = tree.nodes[i];
        const Access_Node &given = nodes[i];
        const float *b = held.bounds;
        if (held.id != given.id || held.parent != given.parent || held.role != given.role ||
            held.states != given.states || b[0] != given.bounds[0] || b[1] != given.bounds[1] ||
            b[2] != given.bounds[2] || b[3] != given.bounds[3] ||
            !same_text(held.name, given.name, given.name_len) ||
            !same_text(held.value, given.value, given.value_len)) {
            return false;
        }
    }
    return true;
}

// Copies the app's nodes and links each to its parent and siblings. Ids are unique and not 0, and a
// parent comes before its children, so the copy is a tree in reading order.
HRESULT build(const Access_Node *nodes, size_t count, uint64_t focus, Tree &out) {
    if (count > static_cast<size_t>(INT_MAX)) return E_INVALIDARG;
    out.nodes.reserve(count);
    out.index.reserve(count);
    for (size_t i = 0; i < count; ++i) {
        const Access_Node &given = nodes[i];
        if (given.id == 0 || given.role >= Role_Count || given.name_len < 0 || given.name_len > INT_MAX ||
            given.value_len < 0 || given.value_len > INT_MAX) {
            return E_INVALIDARG;
        }
        int at = static_cast<int>(i);
        if (!out.index.emplace(given.id, at).second) return E_INVALIDARG;
        int parent = -1;
        if (given.parent != 0) {
            auto found = out.index.find(given.parent);
            if (found == out.index.end() || found->second == at) return E_INVALIDARG;
            parent = found->second;
        }
        Node node{given.id, given.parent, static_cast<Role>(given.role), given.states,
                  std::string(given.name, static_cast<size_t>(given.name_len)),
                  std::string(given.value, static_cast<size_t>(given.value_len)),
                  {given.bounds[0], given.bounds[1], given.bounds[2], given.bounds[3]}};
        node.parent_index = parent;
        int &first = parent < 0 ? out.first_child : out.nodes[parent].first_child;
        int &last = parent < 0 ? out.last_child : out.nodes[parent].last_child;
        if (last >= 0) {
            out.nodes[last].next = at;
            node.previous = last;
        } else {
            first = at;
        }
        last = at;
        out.nodes.push_back(std::move(node));
    }
    if (focus != 0 && !out.index.contains(focus)) return E_INVALIDARG;
    out.focus = focus;
    return S_OK;
}

class Events {
public:
    explicit Events(const std::shared_ptr<Tree> &tree) : tree_(tree) {}

    void structure() {
        keep(UiaRaiseStructureChangedEvent(tree_->root, StructureChangeType_ChildrenInvalidated, nullptr, 0));
    }

    void event(uint64_t id, EVENTID kind) {
        Element *element = make(id);
        if (!element) return;
        keep(UiaRaiseAutomationEvent(element, kind));
        element->Release();
    }

    void text(uint64_t id, PROPERTYID property, const std::string &before, const std::string &after) {
        VARIANT old_value, new_value;
        VariantInit(&old_value);
        VariantInit(&new_value);
        if (keep(text_variant(before, &old_value)) && keep(text_variant(after, &new_value))) {
            raise(id, property, old_value, new_value);
        }
        VariantClear(&old_value);
        VariantClear(&new_value);
    }

    void flag(uint64_t id, PROPERTYID property, bool before, bool after) {
        VARIANT old_value, new_value;
        bool_variant(before, &old_value);
        bool_variant(after, &new_value);
        raise(id, property, old_value, new_value);
    }

    void number(uint64_t id, PROPERTYID property, int before, int after) {
        VARIANT old_value, new_value;
        int_variant(before, &old_value);
        int_variant(after, &new_value);
        raise(id, property, old_value, new_value);
    }

    HRESULT result() const { return first_; }

private:
    Element *make(uint64_t id) {
        auto *element = new (std::nothrow) Element(tree_, id);
        if (!element) keep(E_OUTOFMEMORY);
        return element;
    }

    void raise(uint64_t id, PROPERTYID property, const VARIANT &before, const VARIANT &after) {
        Element *element = make(id);
        if (!element) return;
        keep(UiaRaiseAutomationPropertyChangedEvent(element, property, before, after));
        element->Release();
    }

    bool keep(HRESULT result) {
        if (FAILED(result) && SUCCEEDED(first_)) first_ = result;
        return SUCCEEDED(result);
    }

    std::shared_ptr<Tree> tree_;
    HRESULT first_ = S_OK;
};

// Tells listening assistive technologies what changed between two trees: the structure, what a node
// shows, its state, the notice of a Status node and where focus went.
HRESULT raise_changes(const std::shared_ptr<Tree> &tree, const Tree &before) {
    if (!UiaClientsAreListening()) return S_OK;
    Events events(tree);
    bool structure = before.nodes.size() != tree->nodes.size();
    for (size_t i = 0; !structure && i < tree->nodes.size(); ++i) {
        structure = before.nodes[i].id != tree->nodes[i].id ||
                    before.nodes[i].parent != tree->nodes[i].parent;
    }
    if (structure) events.structure();
    for (const Node &node : tree->nodes) {
        const Node *old = before.find(node.id);
        if (!old || old->role != node.role) {
            if (node.role == Role_Status && !node.name.empty()) {
                events.event(node.id, UIA_LiveRegionChangedEventId);
            }
            continue;
        }
        if (old->name != node.name) {
            events.text(node.id, UIA_NamePropertyId, old->name, node.name);
            if (node.role == Role_Status) events.event(node.id, UIA_LiveRegionChangedEventId);
        }
        if (has_value(node) && old->value != node.value) {
            events.text(node.id, UIA_ValueValuePropertyId, old->value, node.value);
        }
        uint16_t before_states = old->states;
        uint16_t after_states = node.states;
        if (has(before_states ^ after_states, State_Disabled)) {
            events.flag(node.id, UIA_IsEnabledPropertyId, !has(before_states, State_Disabled),
                        !has(after_states, State_Disabled));
        }
        if (has(before_states ^ after_states, State_Focusable)) {
            events.flag(node.id, UIA_IsKeyboardFocusablePropertyId, has(before_states, State_Focusable),
                        has(after_states, State_Focusable));
        }
        if (has_toggle(node) && toggle_state(before_states) != toggle_state(after_states)) {
            events.number(node.id, UIA_ToggleToggleStatePropertyId, toggle_state(before_states),
                          toggle_state(after_states));
        }
        if (has_expand_collapse(node) && expand_state(*old) != expand_state(node)) {
            events.number(node.id, UIA_ExpandCollapseExpandCollapseStatePropertyId, expand_state(*old),
                          expand_state(node));
        }
        if (has_selection_item(node) && has(before_states ^ after_states, State_Selected)) {
            events.flag(node.id, UIA_SelectionItemIsSelectedPropertyId, has(before_states, State_Selected),
                        has(after_states, State_Selected));
        }
    }
    if (tree->focus != before.focus && tree->focus != 0 && ::GetFocus() == tree->window) {
        events.event(tree->focus, UIA_AutomationFocusChangedEventId);
    }
    return events.result();
}

} // namespace

extern "C" {

HRESULT cosmos_uia_create(HWND window, void *user, Request_Proc request, void **out) noexcept {
    *out = nullptr;
    try {
        auto state = std::make_unique<State>();
        state->tree = std::make_shared<Tree>();
        state->tree->window = window;
        state->tree->user = user;
        state->tree->request = request;
        state->root = new Element(state->tree, 0);
        state->tree->root = state->root;
        *out = state.release();
        return S_OK;
    } catch (const std::bad_alloc &) {
        return E_OUTOFMEMORY;
    }
}

// Answers WM_GETOBJECT for UiaRootObjectId.
LRESULT cosmos_uia_answer(void *handle, WPARAM wp, LPARAM lp) noexcept {
    auto &state = *static_cast<State *>(handle);
    state.served = true;
    return UiaReturnRawElementProvider(state.tree->window, wp, lp, state.root);
}

// Replaces the window's tree. S_FALSE means it equals the one held, which is kept. E_INVALIDARG keeps the
// held tree; any other failure is from raising events, after the new tree is in place.
HRESULT cosmos_uia_set(void *handle, const Access_Node *nodes, size_t count, uint64_t focus) noexcept {
    auto &state = *static_cast<State *>(handle);
    Tree &tree = *state.tree;
    if (focus == tree.focus && unchanged(tree, nodes, count)) return S_FALSE;
    try {
        Tree fresh;
        if (HRESULT result = build(nodes, count, focus, fresh); FAILED(result)) return result;
        std::swap(tree.nodes, fresh.nodes);
        std::swap(tree.index, fresh.index);
        std::swap(tree.first_child, fresh.first_child);
        std::swap(tree.last_child, fresh.last_child);
        std::swap(tree.focus, fresh.focus);
        return raise_changes(state.tree, fresh);
    } catch (const std::bad_alloc &) {
        return E_OUTOFMEMORY;
    }
}

// Takes the provider back from UI Automation before the window goes. UiaDisconnectProvider finds what
// clients hold by the provider's runtime id, which the root gets from the window's host provider, so
// every provider is disconnected while the window and the nodes are still in place. Providers an
// assistive technology holds afterwards keep the shared tree alive, emptied, and answer
// UIA_E_ELEMENTNOTAVAILABLE.
HRESULT cosmos_uia_destroy(void *handle) noexcept {
    auto *state = static_cast<State *>(handle);
    Tree &tree = *state->tree;
    HRESULT result = S_OK;
    if (state->served) {
        UiaReturnRawElementProvider(tree.window, 0, 0, nullptr);
        for (const Node &node : tree.nodes) {
            auto *element = new (std::nothrow) Element(state->tree, node.id);
            HRESULT disconnected = element ? UiaDisconnectProvider(element) : E_OUTOFMEMORY;
            if (element) element->Release();
            if (FAILED(disconnected) && SUCCEEDED(result)) result = disconnected;
        }
        HRESULT disconnected = UiaDisconnectProvider(state->root);
        if (FAILED(disconnected) && SUCCEEDED(result)) result = disconnected;
    }
    tree.window = nullptr;
    tree.user = nullptr;
    tree.request = nullptr;
    tree.root = nullptr;
    std::vector<Node>().swap(tree.nodes);
    std::unordered_map<uint64_t, int>().swap(tree.index);
    tree.first_child = tree.last_child = -1;
    tree.focus = 0;
    state->root->Release();
    delete state;
    return result;
}

} // extern "C"
