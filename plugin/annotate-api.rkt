#lang racket

;;; plugin/annotate-api.rkt —— 标注/只读面 SDK 契约（只 re-export，无实现）
;;;
;;; 插件只有两种：
;;;   文档插件 : buffer -> (listof patch)        （增量依据 buffer-dirty）
;;;   view 插件 : window -> (listof status-seg)  （状态行等视口投影）
;;;
;;; 本文件收窄出「插件能且只能」使用的最小合法面：
;;;   - 只读 buffer / window，不导出任何「写 buffer」原语（写是框架的活）
;;;   - 不导出底层 content / properties / marker / overlay 的裸操作
;;;   - 不导出 run-plugins / buffer-apply-patches（插件不该自己跑自己）
;;;
;;; 用法：插件作者只需 (require "../plugin/annotate-api")，参考
;;;       plugin-reference/racket-hl.rkt / status.rkt 的写法。
;;; 注意：本面只能「读 buffer + 写标注（patch）」，不能改文本；
;;;       改文本用编辑面 ../plugin/edit-api.rkt（编辑插件 / 编辑策略）。
;;;
;;; 坐标约定：所有行列都是 0-based 字符索引（列 = 字符数，非显示宽度）。

(require "../core/text/buffer.rkt"
         "../core/text/cursor.rkt"
         "../core/text/patch.rkt"
         "../framework/slots.rkt"
         "../core/view/window.rkt")

(provide
 ;; ═════════════════ 一、声明与输出类型 ═════════════════

 ;; 文档插件声明：把一个 buffer→patch 函数注册进框架。
 ;; 输入: name  symbol                        插件名（依赖据此引用）
 ;;       plugin (-> buffer (listof patch))   插件本体（闭包可带内部状态）
 ;;       deps  (listof symbol)               依赖的插件名（空=独立可并行，非空=串行在其后）
 ;;       mode  (or/c 'sync 'parallel)        执行线程：单核内联 / future 多核
 ;; 输出: plugin-spec
 plugin-spec

 ;; 文档插件的产出：一次增量推导（应用时先清范围内该 key 旧值，再写 segs）。
 ;; 输入: key        any                            归属键（不同插件写不同 key 才能并集合并）
 ;;       first-line nat                            本次重推导的起始行（含，0-based）
 ;;       last-line  nat                            本次重推导的结束行（含）
 ;;       segs       (listof (list line start end val))
 ;;                                                 line/start/end: nat（0-based 字符索引）
 ;;                                                 val: any（标注值，语义 face 等）
 ;; 输出: patch
 patch
 patch-key         ; 输入: patch → 输出: any（归属键）
 patch-first-line  ; 输入: patch → 输出: nat（起始行，含）
 patch-last-line   ; 输入: patch → 输出: nat（结束行，含）
 patch-segs        ; 输入: patch → 输出: (listof (list nat nat nat any))

 ;; view 插件的产出：状态行的一段。
 ;; 输入: text string         文本内容
 ;;       face (or/c #f symbol) 语义 face（#f=无样式；由主题映射成颜色/属性）
 ;; 输出: status-seg
 status-seg
 status-seg-text   ; 输入: status-seg → 输出: string
 status-seg-face   ; 输入: status-seg → 输出: (or/c #f symbol)

 ;; ═════════════════ 二、buffer 只读（两类插件都用） ═════════════════

 buffer-dirty         ; 输入: buffer → 输出: (or/c #f dirty-desc)  增量依据（无编辑=#f）
 buffer-tick          ; 输入: buffer → 输出: nat                   任何变化 +1（含标注写入）
 buffer-line-count    ; 输入: buffer → 输出: nat                   总行数（≥1）
 buffer-line-ref      ; 输入: buffer nat → 输出: string            第 i 行文本（0-based）
 buffer->string       ; 输入: buffer → 输出: string                全文（\n 分隔）
 buffer->lines        ; 输入: buffer → 输出: (listof string)       各行文本
 buffer-get-text-property ; 输入: buffer nat nat symbol → 输出: any
 ;;                                                              读 (line,col) 处某键标注
 ;;                                                              （可读其它插件写的标注）

 ;; ═════════════════ 三、dirty 增量依据 ═════════════════

 dirty-desc-first-line  ; 输入: dirty-desc → 输出: nat  脏区首行（含，0-based）
 dirty-desc-last-line   ; 输入: dirty-desc → 输出: nat  脏区末行（含）
 dirty-desc-old-count   ; 输入: dirty-desc → 输出: nat  编辑前行数
 dirty-desc-new-count   ; 输入: dirty-desc → 输出: nat  编辑后行数

 ;; ═════════════════ 四、位置 cursor（0-based 字符索引） ═════════════════

 cursor        ; 输入: nat nat → 输出: cursor   (line col)
 cursor-line   ; 输入: cursor → 输出: nat       行
 cursor-col    ; 输入: cursor → 输出: nat       列（字符索引，非显示列）
 cursor<?      ; 输入: cursor cursor → 输出: boolean  字典序（先行后列）严格小于
 cursor=?      ; 输入: cursor cursor → 输出: boolean  相等
 cursor<=?     ; 输入: cursor cursor → 输出: boolean  小于或等于
 cursor-clamp  ; 输入: cursor nat (nat→nat) → 输出: cursor
 ;;            ;       位置   总行数   第 i 行长度函数    夹紧到合法行列

 ;; ═════════════════ 五、window 只读（view 插件用） ═════════════════

 window-buffer   ; 输入: window → 输出: buffer          当前文档
 window-point    ; 输入: window → 输出: cursor          本窗口光标
 window-mode     ; 输入: window → 输出: (or/c 'clip 'wrap)
 window-top-line ; 输入: window → 输出: nat             clip: 顶 buffer 行；wrap: 顶部所在行
 window-left-col ; 输入: window → 输出: nat             clip: 水平滚动列；wrap: 恒 0
 window-top-seg  ; 输入: window → 输出: nat             wrap: 顶部第几个折行段；clip: 恒 0
 window-height   ; 输入: window → 输出: nat             可见行数
 window-width    ; 输入: window → 输出: nat             可见列数
 )
