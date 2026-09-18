#lang racket

;;; ============================================================================
;;; api.rkt —— core 层对外的唯一入口
;;; ============================================================================
;;;
;;; 一个纯函数式的编辑器核心：只有「底层数据原子 + 它们的纯函数变换」。
;;; 不含多窗口组合 / 布局 / 命令 / 插件 / 后端。所有结构 #:transparent、不可变。
;;;
;;; ── 唯一约定 ────────────────────────────────────────────────
;;;   使用方一律 (require "core/api.rkt")，
;;;   不要直接 require core/text/* 或 core/view/*。
;;;   内部模块按依赖互相 require，是「实现细节」，外部不接触。
;;;
;;; ── 最小原子（组合出一个编辑器只需要这些）──────────────────────
;;;
;;;   【数据：来回传的「东西」】
;;;   buffer      文档：文本 + 属性 + 标记 + 装饰（无光标）
;;;   events      输入：text/key/mouse/resize/quit（后端喂进来）
;;;   screen      输出：一帧画面（每行几段 run + 一个光标，交给后端画）
;;;
;;;   【操作：真正的「API」只有这两个】
;;;   window      视口：buffer 引用 + 光标 + 滚动 + 尺寸
;;;               · 编辑：window-insert-char/newline/backspace/delete
;;;               · 导航：window-goto/left/right/home/end + window-visual-move
;;;               · 状态：window-set-* / window-scroll / window-ensure-point
;;;   window->screen  投影：window 可见区 → screen（纯函数，无副作用）
;;;
;;; ── 两条数据流 ──────────────────────────────────────────────
;;;
;;;   编辑流：
;;;     events → window-* 原语 → buffer-* → 新 buffer + edit-desc
;;;     （window-* 会自动换新 buffer、把光标推到编辑后位置）
;;;
;;;   渲染流：
;;;     buffer → render-line → glyph → line-range->runs → run
;;;            → window->screen → screen → 后端画出来
;;;
;;; ── 属性怎么参与（关键）──────────────────────────────────────
;;;   属性不是和 screen 拼的，是「存在 buffer 里」的：
;;;
;;;     buffer-put-property b 0 1 7 'face 'keyword   ; 写一次
;;;       │  编辑时 properties-apply-edit 让属性跟着文本自动移动
;;;       ▼
;;;     window->screen 投影时，render-line 把该位置的属性读出来
;;;       │  变成 glyph 的 face
;;;       ▼
;;;     screen 里的 run.face = (hash 'face 'keyword)
;;;       │  后端 (hash-ref (run-face r) 'face) → 主题 → 颜色
;;;       ▼
;;;     终端显示蓝色
;;;
;;;   你只需要一个写入口 buffer-put-property / buffer-put-properties-many；
;;;   之后全是自动的。
;;;
;;; ── read-only 区域（显示 + 输入）──────────────────────────────
;;;   'read-only #t 标成用户不可编辑（如提示区）；编辑在 splice 层被拦截，
;;;   且 read-only 是「硬边界」：边界插入什么都不继承，新输入保持干净。
;;;   程序要编辑 read-only 内容：with-read-only-inhibited 绕过。
;;;
;;;     (buffer-put-property b 0 0 2 'read-only #t)   ; "> " 不可编辑
;;;     ;; 光标放输入区，打字只落在可编辑处；backspace 到边界就删不动
;;;
;;; ── 最小编辑器骨架 ──────────────────────────────────────────
;;;
;;;   (define b (buffer-open "hello"))            ; 开文档
;;;   (define w (window-open b 24 80))            ; 开视口
;;;   (define s (window->screen w))               ; 投影成画面
;;;   ;; 后端画 s；后端喂入一个 event：
;;;   (define-values (w* desc) (window-insert-char w #\X))  ; 处理 text-event
;;;   ;; w* 的 buffer 已换新、光标已推进；desc 给上层做同步/撤销
;;;
;;; ── 唯一跨层契约 ────────────────────────────────────────────
;;;   edit-desc (s-line s-col e-line e-col new-text)
;;;   一次编辑 = 删除 [s..e) + 插入 new-text（所有编辑都是它的特例）。
;;;   编辑原语返回 (values 新值 desc)，无操作 desc = #f；
;;;   导航/状态原语直接返回 window。
;;;
;;; ── 导出边界（内部实现不对外）────────────────────────────────
;;;   对外（消费者层）：point buffer window screen events edit-desc patch width document
;;;   对外（机制层）：buffer-splice / buffer-apply-edits、marker/overlay 的 buffer 级入口、
;;;                dirty-desc、with-read-only-inhibited
;;;   藏起来（内部实现）：content-* properties-* marker-table-* overlay-table-*
;;;                     render-* vrow/layout/wrap/window-vrows
;;; ============================================================================

(require "text/point.rkt"
         "text/content.rkt"
         "text/buffer.rkt"
         "text/edit.rkt"
         "text/patch.rkt"
         "view/events.rkt"
         "view/width.rkt"
         "view/screen.rkt"
         "view/window.rkt"
         "view/view.rkt"
         "view/project.rkt"
         "view/document.rkt")

(provide
 ;; ---- 消费者层：写编辑器就用这些 ----
 (all-from-out "text/point.rkt")       ; point —— (line,col) 位置
 ;; content.rkt 只露 edit-desc 契约，文本存储本身（含 struct:content）是内部实现
 (except-out (all-from-out "text/content.rkt")
             content content? struct:content content-lines content-gap-line content-gap-col
             make-content content-of-lines content-of-string string->lines
             content->lines content->string content-current-line content-line-count
             content-line-ref content-check content-set-col content-gap-up
             content-gap-down content-gap-goto content-splice content-insert-char
             content-insert-string content-newline content-backspace content-delete)
 ;; buffer.rkt：文档原子；去重 edit-desc（以 content.rkt 为唯一来源）
 (except-out (all-from-out "text/buffer.rkt")
             edit-desc edit-desc? edit-desc-s-line edit-desc-s-col
             edit-desc-e-line edit-desc-e-col edit-desc-new-text edit-desc-after-position)
 (all-from-out "text/edit.rkt")        ; 批量编辑应用 + 点映射（机制）
 (all-from-out "text/patch.rkt")       ; patch —— 补丁 delta（机制）
 ;; ---- 视口层 ----
 (all-from-out "view/events.rkt")      ; 类型化输入事件
 (all-from-out "view/width.rkt")       ; 字符 ↔ 显示列（宽字符宽度，供上层截断/量宽）
 (all-from-out "view/screen.rkt")      ; run + screen + diff + compose（输出）
 (all-from-out "view/window.rkt")      ; window —— 视口 + 编辑/导航
 ;; view.rkt 只露窗口级操作，布局内部（含 struct:vrow）藏起来
 (except-out (all-from-out "view/view.rkt")
             vrow vrow? struct:vrow vrow-line vrow-start-col vrow-end-col
             line-range->runs wrap-segments layout-clip layout-wrap window-vrows)
 (all-from-out "view/project.rkt")    ; window->screen —— 投影成画面
 (all-from-out "view/document.rkt"))  ; document —— 共享 buffer 的多窗口同步

;;; ============================================================================
;;; 冒烟测试：验证门面 + 一条完整的「属性 → 画面」链
;;; ============================================================================

(module+ test
  (require rackunit)

  ;; 门面转发后，核心绑定可用
  (define b (buffer-open "hello\nworld"))
  (check-equal? (buffer->string b) "hello\nworld")
  (check-equal? (buffer-line-count b) 2)

  ;; 编辑闭环：插入字符 → 窗口光标推进 → 渲染出新文本
  (define w (window-open b 2 10))
  (check-equal? (window-point w) (point 0 0))
  (define-values (w2 desc) (window-insert-char w #\X))
  (check-equal? (buffer->string (window-buffer w2)) "Xhello\nworld")
  (check-equal? desc (edit-desc 0 0 0 0 "X"))
  (check-equal? (window-point w2) (point 0 1))
  (check-equal? (screen-rows (window->screen w2)) 2)

  ;; 属性链：写进 buffer → 自动流进 screen 的 run.face
  (define b3 (buffer-put-property b 0 0 5 'face 'keyword))
  (define s3 (window->screen (window-open b3 2 10)))
  (define row0 (vector-ref (screen-row-runs s3) 0))
  (check-equal? (car row0) (run 0 "hello" (hash 'face 'keyword)))

  ;; 属性随编辑移动：在属性区间前插一个字符 → 区间整体右移。
  ;; 插入点在左邻为空处，新字符不继承（继承左邻规则）；"hello" 仍带 keyword。
  (define-values (w4 _) (window-insert-char (window-open b3 2 10) #\Z))
  (define s4 (window->screen w4))
  (check-equal? (vector-ref (screen-row-runs s4) 0)
                (list (run 0 "Z" (hash))
                      (run 1 "hello" (hash 'face 'keyword))))

  (displayln "api.rkt: all tests passed"))
