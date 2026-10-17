#lang racket

;;; effects/panel.rkt —— 面板 ↔ 引擎的适配原语（不纯）
;;; layer  : effects
;;; effect : **IO**：创建/销毁 engine 对象（panel-create-view! / panel-uninstall!）、
;;;            写面板 buffer（panel-sync-buffer!）

;;; 一个“buffer 支撑的面板”在四处留痕：
;;;
;;;   engine    : 一个 document + 一个 view（唯一可变边界，句柄不进 State）
;;;   workspace : doc-meta / view-meta / region（纯数据，在 State 里）
;;;   layout    : 引用 region-id 的叶子（由调用方决定插在哪，本模块不管）
;;;   插件切片   : 自己的 view-id / 展开集合 / 宽度 …（插件的 State.store）
;;;
;;; 前两件是**同构动作**，所以抽到这里，让每个面板只剩“行投影 + 命令 + sync”：
;;;
;;;   panel-create-view!    分配 doc/view id -> engine 建对象 -> 写 meta
;;;   panel-region-add!     把一个 view 加进 region（region 不存在就建）；active = 该 view
;;;   panel-region-install! 一次建 region（多个成员 + 指定 active）；chrome 槽用
;;;   panel-install!        create-view + region-add（单 view 面板）
;;;   panel-uninstall!      region 内 view/doc + engine 对象 + region + layout 剪枝
;;;   panel-sync-buffer!    把 (texts, faces) 写进 buffer view，光标夹在文本内
;;;   panel-visible?        该 view 是否是所在 region 的 active 成员，且 region 在布局里可见
;;;
;;; 面板**不**自己分配 id、不自己 new region、不自己写 focus 规则：
;;; 这些都属于装配层，插件只声明参数（name / mode / role / 是否可聚焦由 role 决定）。

(provide panel-create-view!
         panel-region-add!
         panel-region-install!
         panel-visible?
         panel-install!
         panel-uninstall!
         panel-sync-buffer!)

(require "../base/id.rkt"
         "../model/state.rkt"
         "../model/workspace.rkt"
         "../model/layout.rkt"
         "../effects/engine.rkt"
         "../../core/editor/ops.rkt"
         "../../core/editor/attributes.rkt"
         "../../core/editor/query.rkt"
         "../../core/editor/state.rkt"
         "../../core/text/base/point.rkt"
         "../../core/text/base/selection.rkt"
         "../../core/text/base/range.rkt")

;;; ════════════════ 建 ════════════════

;; 按 panel-spec 装一个面板（宿主给的 region-id 决定它落在布局哪里）。
;; 这里只做“spec -> 参数”的转发：面板身份由插件声明，安装由宿主触发。

;; 建一个空白的 document + view。
;;   name / mode -> doc-meta；options -> view-meta
;;   internal? 默认 #t：面板 / chrome 的文档是基础设施，不参与保存/资源列表/placement
;; → (values state' view-id)
(define (panel-create-view! engine state
                            #:name [name "*panel*"]
                            #:mode [mode 'text]
                            #:options [options (hash)]
                            #:internal? [internal? #t])
  (define-values (did s1) (state-next-id state 'doc))
  (define-values (vid s2) (state-next-id s1 'view))
  (void (engine-create-doc! engine did name ""))
  (void (engine-create-view! engine vid did))
  (define ws (state-workspace s2))
  (define ws1 (workspace-add-doc ws did
                                 (make-doc-meta name #:mode mode #:internal? internal?)))
  (define ws2 (workspace-add-view ws1 vid (view-meta did options)))
  (values (state-set-workspace s2 ws2) vid))

;; 把一个 view 加进 region；region 不存在就用 role 建一个。
;;   · region 已存在 -> 保留它的 role（同一区域放多个面板时，role 由第一个决定）；
;;   · 成员已存在 -> 只把它设为 active（幂等，重复安装同 rid 不会产生重复成员）。
;; 这正是“文件树 + 资源列表共用一个面板位置”的基础：两次 install 传同一个 rid。
(define (panel-region-add! state rid vid #:role [role 'panel])
  (state-workspace*
   state
   (λ (ws)
     (define reg (workspace-region ws rid))
     (cond
       [(not reg)
        (workspace-add-region ws rid
                              (region rid (list (view-member vid)) vid role))]
       [else
        (define members (region-members reg))
        (define members*
          (if (for/or ([m (in-list members)])
                (and (view-member? m) (equal? (member-key m) vid)))
              members
              (append members (list (view-member vid)))))
        (workspace-add-region ws rid
                              (struct-copy region reg
                                           [members members*]
                                           [active vid]))]))))

;; 建一个 region；role 决定 splittable? / close-policy / focusable?（查 env）。
;; active 默认取最后一个成员。
(define (panel-region-install! state rid
                               #:role [role 'panel]
                               #:members [members '()]
                               #:active [active #f])
  (define active*
    (or active
        (and (pair? members) (member-key (last members)))
        #f))
  (state-workspace*
   state
   (λ (ws)
     (workspace-add-region ws rid (region rid members active* role)))))

;; 面板：建 view + 加进 region（同名 rid => 与已有面板共用一块位置）。
(define (panel-install! engine state rid
                        #:name [name "*panel*"]
                        #:mode [mode 'text]
                        #:role [role 'panel])
  (define-values (s1 vid) (panel-create-view! engine state #:name name #:mode mode))
  (values (panel-region-add! s1 rid vid #:role role) vid))

;;; ════════════════ 可见性（面板是否被同一 region 的其它成员挡住） ════════════════

;; 每帧同步用它做闸门：被别的成员挡住、或整个 region 被隐藏时，不重建文本
;; （文件树因此不会在后台扫盘）。
(define (panel-visible? state vid)
  (define ws (state-workspace state))
  (define reg (workspace-view-region ws vid))
  (and reg
       (equal? (region-active reg) vid)
       (tree-visible? (workspace-layout ws) (region-key reg))
       #t))

;;; ════════════════ 拆 ════════════════

;; 卸载一个面板 = 反着走一遍：
;;   · region 内每个 view：engine 销毁 view + workspace 摘掉 view；
;;   · 每个 doc：engine 销毁 doc + workspace 摘掉 doc（防止残留 doc-meta）；
;;   · region 本身：摘掉，同时把 layout 里引用它的叶子剪掉（tree-close）。
;;
;; 插件自己的 State 切片（view-id / 展开集合 …）由调用方清，本模块不猜。
;; region 不存在时是 no-op（可重复调用）。
(define (panel-uninstall! engine state rid)
  (define ws (state-workspace state))
  (define reg (workspace-region ws rid))
  (cond
    [(not reg) state]
    [else
     (define vids
       (for/list ([m (in-list (region-members reg))] #:when (view-member? m))
         (member-key m)))
     (define dids
       (remove-duplicates
        (filter values
                (for/list ([vid (in-list vids)])
                  (workspace-doc-of-view ws vid)))))
     (define s1
       (for/fold ([s state]) ([vid (in-list vids)])
         (engine-remove-view! engine vid)
         (state-workspace* s (λ (w) (workspace-remove-view w vid)))))
     (define s2
       (for/fold ([s s1]) ([did (in-list dids)])
         (engine-remove-doc! engine did)
         (state-workspace* s (λ (w) (workspace-remove-doc w did)))))
     (state-workspace* s2 (λ (w) (workspace-remove-region w rid)))]))

;;; ════════════════ 每帧同步 ════════════════

;; 把行投影写进 buffer 支撑的 view：
;;   · 文本变化才重写 buffer（避免每帧 undo 记录 / 版本抖动）；
;;   · face 每帧重写（很便宜，且行的分类可能因外部状态变化）；
;;   · 光标行 / 列夹到新文本范围内；
;;   · #:ensure? 只在聚焦时滚动到光标（不抢别的面板的 viewport）。
;;
;; texts : (listof string)；faces : (listof (or/c symbol #f))（#f 表示不设 face）
(define (panel-sync-buffer! engine state vid
                            #:texts [texts '()]
                            #:faces [faces '()])
  (define v (engine-view-object engine vid))
  (when v
    (define b (view-buffer v))
    (define text (string-join texts "\n"))
    (define old-line (view-point-line v))
    (define old-col (view-point-column v))
    (unless (string=? text (buffer-string b))
      (buffer-set-document! b text))
    (for ([t (in-list texts)] [f (in-list faces)] [i (in-naturals)])
      (when f
        (buffer-face-range! b
                            (range-of (point i 0) (point i (string-length t)))
                            f)))
    (define n (length texts))
    (define line (if (zero? n) 0 (min old-line (sub1 n))))
    (define lstr (if (zero? n) "" (list-ref texts line)))
    (define col (min old-col (string-length lstr)))
    (view-set-selections! v
                          (selections-one (caret (point line col)))
                          #:ensure? (equal? (state-focus state) vid)))
  (void))
