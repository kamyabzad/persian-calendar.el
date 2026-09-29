;;; persian-calendar.el --- Persian (Jalali) display for M-x calendar -*- lexical-binding: t; -*-

;; Copyright (C) 2026 Kamyab Taghizadeh

;; Author: Kamyab Taghizadeh <kamyabzad@gmail.com>
;; Version: 0.1.0
;; Package-Requires: ((emacs "31.1"))
;; Keywords: calendar, i18n
;; URL: https://github.com/kamyabzad/persian-calendar.el

;; This program is free software: you can redistribute it and/or modify
;; it under the terms of the GNU General Public License as published by
;; the Free Software Foundation, either version 3 of the License, or
;; (at your option) any later version.

;; This program is distributed in the hope that it will be useful,
;; but WITHOUT ANY WARRANTY; without even the implied warranty of
;; MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
;; GNU General Public License for more details.

;; You should have received a copy of the GNU General Public License
;; along with this program.  If not, see <https://www.gnu.org/licenses/>.

;;; Commentary:

;; This package makes the visual `M-x calendar' grid display the
;; Persian (Jalali) calendar.  Emacs's bundled cal-persia.el only
;; provides date conversions; the grid itself is hardcoded Gregorian.
;;
;; Enable `persian-calendar-mode' in the calendar buffer to switch the
;; three-month window to three Persian months, with Farsi month and
;; day names, the week starting on Saturday, and Friday as the
;; weekend.  Toggling the mode off restores the stock Gregorian grid.
;;
;; While the mode is active, every date crossing a function boundary
;; remains Gregorian: `calendar-cursor-to-date' converts the Persian
;; cell under point back to its Gregorian equivalent, so diary
;; marking, org-agenda integration, `calendar-goto-date', sunrise and
;; lunar commands all keep working unchanged.  Only the displayed
;; window is Persian.
;;
;; Set `persian-calendar-auto-enable' to a non-nil value to have every
;; new calendar window open in Persian mode.  A suggested binding:
;;
;;   (define-key calendar-mode-map "P" #'persian-calendar-mode)
;;
;; Holidays are not supported while the mode is active.
;; `calendar-show-more-months' and `calendar-show-fewer-months' are
;; not supported in Persian mode either.
;;
;; cal-persia.el implements the arithmetic (Birashk 2820-year cycle)
;; Persian calendar, which differs from Iran's official astronomical
;; calendar during 1403-1404, and again around 1436-1437 and
;; 1469-1470 (Birashk misplaces the leap year at those cycle
;; boundaries).  By default this package corrects that globally:
;; `persian-calendar-official-calendar' overrides cal-persia's
;; conversions with the 33-year cycle algorithm (Toossi/Pournader, as
;; in jalaali-js), which matches the official calendar exactly for
;; 1178-1633 AP.  Set it to nil to keep cal-persia's arithmetic.

;;; Code:

(require 'calendar)
(require 'cal-persia)
(require 'cal-move)

(defvar displayed-month)
(defvar displayed-year)
(defvar calendar-mark-holidays)
(defvar calendar-recenter-last-op)
(defvar persian-calendar-mode)

(declare-function calendar-mark-month "diary-lib"
                  (month year p-month p-day p-year &optional color))

(defgroup persian-calendar nil
  "Persian (Jalali) display for the calendar."
  :group 'calendar
  :prefix "persian-calendar-")

(defcustom persian-calendar-month-name-array
  ["فروردین" "اردیبهشت" "خرداد" "تیر" "مرداد" "شهریور"
   "مهر" "آبان" "آذر" "دی" "بهمن" "اسفند"]
  "Farsi names of the twelve Persian months."
  :type '(vector string string string string string string
                 string string string string string string))

(defcustom persian-calendar-day-header-array
  ["ی" "د" "س" "چ" "پ" "ج" "ش"]
  "Farsi day-of-week column headers, in Sunday-first order.
With `calendar-week-start-day' 6 the Saturday header appears in the
first column."
  :type '(vector string string string string string string string))

(defconst persian-calendar-day-header-latin-array
  ["Ye" "Do" "Se" "Ch" "Pa" "Jo" "Sh"]
  "Transliterated day-of-week column headers, in Sunday-first order.")

(defcustom persian-calendar-day-name-array
  ["یکشنبه" "دوشنبه" "سه‌شنبه" "چهارشنبه" "پنجشنبه" "جمعه" "شنبه"]
  "Farsi names of the days of the week, in Sunday-first order."
  :type '(vector string string string string string string string))

(defcustom persian-calendar-week-start-day 6
  "First day of the week on the Persian grid, Sunday-first indexing.
The default is Saturday.  While `persian-calendar-mode' is active this
value shadows `calendar-week-start-day' buffer-locally."
  :type 'integer)

(defcustom persian-calendar-weekend-days '(5)
  "Days considered the weekend on the Persian grid, Sunday-first indexing.
The default is Friday."
  :type '(repeat integer))

(defcustom persian-calendar-use-farsi-names t
  "If non-nil, use Farsi month and day names on the grid.
If nil, fall back to Latin transliterations, which avoids any
font-width or bidi rendering issues."
  :type 'boolean)

(defcustom persian-calendar-month-header
  '(propertize (format "%s\u200e %d\u200e"
                       (persian-calendar-month-name month) year)
               'font-lock-face 'calendar-month-header)
  "Expression evaluated to produce a Persian month heading.
During evaluation `month' and `year' are bound to Persian values."
  :risky t
  :type 'sexp)

(defcustom persian-calendar-auto-enable nil
  "If non-nil, enable `persian-calendar-mode' in every new calendar window."
  :type 'boolean)

(defcustom persian-calendar-official-calendar t
  "If non-nil, use Iran's official calendar instead of cal-persia's arithmetic.
cal-persia implements Birashk's 2820-year cycle, which disagrees with
the official astronomical calendar during 1403-1404, 1436-1437 and
1469-1470 (it misplaces the leap year).  When this is non-nil, the 33-year cycle
algorithm (Toossi/Pournader, as in jalaali-js) replaces cal-persia's
conversions globally; it matches the official calendar exactly for the
years 1178-1633 AP.  This affects every user of the cal-persia
functions, not just the calendar grid, so Persian dates shown in
Org mode and diary stay consistent with the grid."
  :type 'boolean)

(defconst persian-calendar--jal-breaks
  [-61 9 38 199 426 686 756 818 1111 1181 1210
   1635 2060 2097 2192 2262 2324 2394 2456 3178]
  "Breakpoint years of the 33-year cycle algorithm.")

;; Port of jalCal from jalaali-js; all divisions truncate toward zero,
;; so this uses / and %, never `floor' or `mod'.
(defun persian-calendar--jal-cal (jy)
  "Return (LEAP GYEAR MARCH) for Persian year JY per the 33-year cycles.
LEAP is 0 when JY is a leap year, GYEAR is the Gregorian year of the
start of JY, and MARCH is the day of March of 1 Farvardin JY."
  (let* ((bl (length persian-calendar--jal-breaks))
         (gy (+ jy 621))
         (leap-j -14)
         (jp (aref persian-calendar--jal-breaks 0))
         (jump 0)
         (i 1)
         jm n leap leap-g march)
    (while (< i bl)
      (setq jm (aref persian-calendar--jal-breaks i)
            jump (- jm jp))
      (if (< jy jm)
          (setq i bl)
        (setq leap-j (+ leap-j (* (/ jump 33) 8) (/ (% jump 33) 4))
              jp jm
              i (1+ i))))
    (setq n (- jy jp)
          leap-j (+ leap-j (* (/ n 33) 8) (/ (+ (% n 33) 3) 4)))
    (when (and (= (% jump 33) 4) (= (- jump n) 4))
      (setq leap-j (1+ leap-j)))
    (setq leap-g (- (/ gy 4) (/ (* (1+ (/ gy 100)) 3) 4) 150)
          march (+ 20 (- leap-j leap-g)))
    (when (< (- jump n) 6)
      (setq n (+ (- n jump) (* (/ (+ jump 4) 33) 33))))
    (setq leap (% (1- (% (1+ n) 33)) 4))
    (when (= leap -1) (setq leap 4))
    (list leap gy march)))

(defun persian-calendar--jal-in-range-p (jy)
  "Return non-nil if Persian year JY is covered by the 33-year cycles."
  (and (>= jy 2) (< jy 3178)))

(defun persian-calendar--official-leap-year-p (year)
  "Return non-nil if Persian YEAR is leap on the official calendar."
  (zerop (nth 0 (persian-calendar--jal-cal year))))

(defun persian-calendar--official-to-absolute (date)
  "Compute the absolute date of official Persian DATE."
  (let* ((jm (calendar-extract-month date))
         (jd (calendar-extract-day date))
         (jy (calendar-extract-year date))
         (r (persian-calendar--jal-cal jy)))
    (+ (calendar-absolute-from-gregorian (list 3 (nth 2 r) (nth 1 r)))
       (* (1- jm) 31)
       (- (* (/ jm 7) (- jm 7)))
       (1- jd))))

(defun persian-calendar--official-from-absolute (date)
  "Compute the official Persian equivalent of absolute date DATE."
  (let* ((gy (calendar-extract-year
              (calendar-gregorian-from-absolute date)))
         (jy (- gy 621))
         (r (persian-calendar--jal-cal jy))
         (k (- date (calendar-absolute-from-gregorian
                     (list 3 (nth 2 r) gy))))
         jm jd)
    (cond
     ((and (>= k 0) (<= k 185))
      (setq jm (1+ (/ k 31))
            jd (1+ (% k 31))))
     ((>= k 0)
      (setq k (- k 186)
            jm (+ 7 (/ k 30))
            jd (1+ (% k 30))))
     (t
      (setq jy (1- jy)
            k (+ k 179))
      (when (= (nth 0 r) 1)
        (setq k (1+ k)))
      (setq jm (+ 7 (/ k 30))
            jd (1+ (% k 30)))))
    (list jm jd jy)))

(defun persian-calendar--ad-persian-leap-year-p (orig year)
  "Use the official leap-year rule for YEAR when configured.
ORIG is the advised function."
  (if (and persian-calendar-official-calendar
           (persian-calendar--jal-in-range-p year))
      (persian-calendar--official-leap-year-p year)
    (funcall orig year)))

(defun persian-calendar--ad-persian-to-absolute (orig date)
  "Use the official conversion for Persian DATE when configured.
ORIG is the advised function."
  (if (and persian-calendar-official-calendar
           (persian-calendar--jal-in-range-p (calendar-extract-year date)))
      (persian-calendar--official-to-absolute date)
    (funcall orig date)))

(defun persian-calendar--ad-persian-from-absolute (orig date)
  "Use the official conversion for absolute DATE when configured.
ORIG is the advised function."
  (if (and persian-calendar-official-calendar
           (persian-calendar--jal-in-range-p
            (- (calendar-extract-year
                (calendar-gregorian-from-absolute date))
               621)))
      (persian-calendar--official-from-absolute date)
    (funcall orig date)))

(defun persian-calendar--from-gregorian (date)
  "Return the Persian (MONTH DAY YEAR) equivalent of Gregorian DATE."
  (calendar-persian-from-absolute (calendar-absolute-from-gregorian date)))

(defun persian-calendar--to-gregorian (date)
  "Return the Gregorian (MONTH DAY YEAR) equivalent of Persian DATE."
  (calendar-gregorian-from-absolute (calendar-persian-to-absolute date)))

(defun persian-calendar-month-name (month)
  "Return the display name of Persian month number MONTH."
  (aref (if persian-calendar-use-farsi-names
            persian-calendar-month-name-array
          calendar-persian-month-name-array)
        (1- month)))

(defun persian-calendar--day-header (j)
  "Return the column header for day-of-week J (Sunday-first indexing)."
  (aref (if persian-calendar-use-farsi-names
            persian-calendar-day-header-array
          persian-calendar-day-header-latin-array)
        j))

(defun persian-calendar--active-p ()
  "Return non-nil if the Persian display is active in the calendar buffer."
  (if (derived-mode-p 'calendar-mode)
      persian-calendar-mode
    (let ((buf (get-buffer calendar-buffer)))
      (and buf (buffer-local-value 'persian-calendar-mode buf)))))

(defun persian-calendar--align-space (column &optional width)
  "Return WIDTH spaces (default 1) displayed as a stretch ending at COLUMN.
Farsi glyphs rarely render at exactly one column width in a GUI, so
plain-space padding lets a pixel error accumulate across header cells;
the stretch pins the pixel position back to the logical COLUMN."
  (propertize (make-string (or width 1) ?\s)
              'display `(space :align-to ,column)))

(defun persian-calendar--generate-month (month year indent)
  "Produce a calendar for Persian MONTH, YEAR indented INDENT spaces."
  (let ((blank-days
         (mod (- (calendar-day-of-week
                  (persian-calendar--to-gregorian (list month 1 year)))
                 calendar-week-start-day)
              7))
        (last (calendar-persian-last-day-of-month month year))
        (trunc (min calendar-intermonth-spacing
                    (1- calendar-left-margin)))
        (day 1)
        j)
    (goto-char (point-min))
    (calendar-move-to-column indent)
    (insert
     (calendar-dlet ((month month) (year year))
       (calendar-string-spread (list persian-calendar-month-header)
                               ?\s calendar-month-digit-width))
     (persian-calendar--align-space
      (+ indent calendar-month-digit-width 1)))
    (calendar-ensure-newline)
    (calendar-insert-at-column indent calendar-intermonth-header trunc)
    (dotimes (i 7)
      (setq j (mod (+ calendar-week-start-day i) 7))
      (insert
       (truncate-string-to-width
        (propertize (concat (persian-calendar--day-header j) "\u200e")
                    'font-lock-face (if (memq j calendar-weekend-days)
                                        'calendar-weekend-header
                                      'calendar-weekday-header))
        calendar-day-header-width nil ?\s)
       (persian-calendar--align-space
        (+ indent (* (1+ i) calendar-column-width))
        (- calendar-column-width calendar-day-header-width))))
    (calendar-ensure-newline)
    (calendar-dlet ((day day) (month month) (year year))
      (calendar-insert-at-column indent calendar-intermonth-text trunc))
    (insert (make-string (* blank-days calendar-column-width) ?\s))
    (dotimes (i last)
      (setq day (1+ i))
      (insert (propertize
               (format (format "%%%dd" calendar-day-digit-width) day)
               'mouse-face 'highlight
               'help-echo (calendar-dlet ((day day) (month month) (year year))
                            (eval calendar-date-echo-text t))
               'date t)
              (make-string
               (- calendar-column-width calendar-day-digit-width) ?\s))
      (when (and (zerop (mod (+ day blank-days) 7))
                 (/= day last))
        (calendar-ensure-newline)
        (setq day (1+ day))
        (calendar-dlet ((day day) (month month) (year year))
          (calendar-insert-at-column indent calendar-intermonth-text trunc))))))

(defun persian-calendar--show-pmonth-at-edge (pmonth pyear arg)
  "Regenerate with Persian PMONTH, PYEAR at the window edge.
The month is placed at the right edge if ARG is positive, at the left
edge otherwise."
  (pcase-let* ((`(,m1 ,y1 ,m2 ,y2) (calendar-get-month-range))
               (offset (if (> arg 0)
                           (calendar-interval m2 y2 pmonth pyear)
                         (calendar-interval m1 y1 pmonth pyear))))
    (calendar-increment-month m1 y1 (1+ offset))
    (calendar-generate-window m1 y1)))

(defvar persian-calendar--repositioning nil)

(defun persian-calendar--ad-generate-window (orig &optional mon yr)
  "Supply today's Persian month and year when MON and YR are nil.
ORIG is the advised function."
  (if (not (persian-calendar--active-p))
      (funcall orig mon yr)
    (unless (and mon yr)
      (let ((ptoday (persian-calendar--from-gregorian
                     (calendar-current-date))))
        (setq mon (calendar-extract-month ptoday)
              yr (calendar-extract-year ptoday))))
    (funcall orig mon yr)))

(defun persian-calendar--ad-generate (orig month year)
  "Generate three Persian months centered around Persian MONTH, YEAR.
ORIG is the advised function."
  (if (not (persian-calendar--active-p))
      (funcall orig month year)
    (when (< year 1)
      (user-error "Persian years before 1 cannot be displayed"))
    (setq displayed-month month
          displayed-year year)
    (erase-buffer)
    (calendar-increment-month month year -1)
    (dotimes (i calendar-total-months)
      (persian-calendar--generate-month month year
                                        (+ calendar-left-margin
                                           (* calendar-month-width i)))
      (calendar-increment-month month year 1))))

(defun persian-calendar--ad-cursor-to-date (orig &optional error event)
  "Return the Gregorian date of the Persian cell under the cursor.
ORIG is the advised function; ERROR and EVENT are as in
`calendar-cursor-to-date'."
  (if (not (persian-calendar--active-p))
      (funcall orig error event)
    (with-current-buffer
        (if event (calendar-event-buffer event)
          (current-buffer))
      (save-excursion
        (and event (setq event (event-start event))
             (integerp (posn-point event))
             (goto-char (posn-point event)))
        (let* ((segment (calendar-column-to-segment))
               (month-index (+ displayed-month (1- segment)))
               (month (% month-index 12)))
          (if (not (and (looking-at "[ 0-9]?[0-9][^0-9]")
                        (get-text-property (point) 'date)))
              (if error (user-error "Not on a date!"))
            (if (zerop month) (setq month 12))
            (or (looking-at " ")
                (re-search-backward "[^0-9]"))
            (persian-calendar--to-gregorian
             (list month
                   (string-to-number
                    (buffer-substring (1+ (point))
                                      (+ 1 calendar-day-digit-width (point))))
                   (cond
                    ((< month-index 1) (1- displayed-year))
                    ((> month-index 12) (1+ displayed-year))
                    (t displayed-year))))))))))

(defun persian-calendar--ad-cursor-to-visible-date (orig date)
  "Move the cursor to Gregorian DATE on the Persian grid.
ORIG is the advised function."
  (if (not (persian-calendar--active-p))
      (funcall orig date)
    (let ((pdate (persian-calendar--from-gregorian date)))
      (unless (or persian-calendar--repositioning
                  (calendar-date-is-visible-p date))
        (let ((persian-calendar--repositioning t))
          (calendar-generate-window (calendar-extract-month pdate)
                                    (calendar-extract-year pdate))))
      (let ((month (calendar-extract-month pdate))
            (day (calendar-extract-day pdate))
            (year (calendar-extract-year pdate)))
        (goto-char (point-min))
        (forward-line (+ calendar-first-date-row -1
                         (/ (+ day -1
                               (mod
                                (- (calendar-day-of-week
                                    (persian-calendar--to-gregorian
                                     (list month 1 year)))
                                   calendar-week-start-day)
                                7))
                            7)))
        (move-to-column (+ calendar-left-margin (1- calendar-day-digit-width)
                           (* calendar-month-width
                              (1+ (calendar-interval
                                   displayed-month displayed-year month year)))
                           (* calendar-column-width
                              (mod
                               (- (calendar-day-of-week date)
                                  calendar-week-start-day)
                               7))))))))

(defun persian-calendar--ad-date-is-visible-p (orig date)
  "Return non-nil if Gregorian DATE is visible on the Persian grid.
ORIG is the advised function."
  (if (not (persian-calendar--active-p))
      (funcall orig date)
    (and (calendar-date-is-valid-p date)
         (let ((pdate (persian-calendar--from-gregorian date)))
           (< -2 (calendar-interval
                  displayed-month displayed-year
                  (calendar-extract-month pdate)
                  (calendar-extract-year pdate))
              (1- calendar-total-months))))))

(defun persian-calendar--ad-mark-visible-date (orig date &optional mark)
  "Mark DATE only when it is actually visible on the Persian grid.
ORIG is the advised function."
  (if (not (persian-calendar--active-p))
      (funcall orig date mark)
    (when (with-current-buffer (calendar-get-buffer)
            (calendar-date-is-visible-p date))
      (funcall orig date mark))))

(defun persian-calendar--ad-get-date-range (orig &optional full)
  "Return the Gregorian date range covered by the Persian window.
ORIG is the advised function; FULL is as in `calendar-get-date-range'."
  (if (not (persian-calendar--active-p))
      (funcall orig full)
    (pcase-let ((`(,m1 ,y1 ,m2 ,y2) (calendar-get-month-range)))
      (cons
       (persian-calendar--to-gregorian (list m1 1 y1))
       (persian-calendar--to-gregorian
        (list m2
              (if full (calendar-persian-last-day-of-month m2 y2) 1)
              y2))))))

(defun persian-calendar--ad-mark-date-pattern (orig month day year
                                                    &optional color)
  "Mark dates matching MONTH/DAY/YEAR across the Gregorian span of the window.
ORIG is the advised function."
  (if (not (persian-calendar--active-p))
      (funcall orig month day year color)
    (with-current-buffer (calendar-get-buffer)
      (let* ((range (calendar-get-date-range t))
             (m (calendar-extract-month (car range)))
             (y (calendar-extract-year (car range)))
             (m2 (calendar-extract-month (cdr range)))
             (y2 (calendar-extract-year (cdr range))))
        (while (or (< y y2) (and (= y y2) (<= m m2)))
          (calendar-mark-month m y month day year color)
          (calendar-increment-month m y 1))))))

(defun persian-calendar--ad-mark-days-named (orig dayname &optional color)
  "Mark every DAYNAME across the Gregorian span of the Persian window.
ORIG is the advised function."
  (if (not (persian-calendar--active-p))
      (funcall orig dayname color)
    (with-current-buffer (calendar-get-buffer)
      (let* ((range (calendar-get-date-range t))
             (day (calendar-absolute-from-gregorian (car range)))
             (last-day (calendar-absolute-from-gregorian (cdr range))))
        (setq day (+ day (mod (- dayname (mod day 7)) 7)))
        (while (<= day last-day)
          (calendar-mark-visible-date (calendar-gregorian-from-absolute day)
                                      color)
          (setq day (+ day 7)))))))

(defun persian-calendar--ad-show-month-at-edge (orig month year arg)
  "Place the Persian month containing Gregorian MONTH, YEAR at the edge.
The right edge if ARG is positive, the left edge otherwise.
ORIG is the advised function."
  (if (not (persian-calendar--active-p))
      (funcall orig month year arg)
    (let* ((pdate (persian-calendar--from-gregorian
                   (if (> arg 0)
                       (list month (calendar-last-day-of-month month year)
                             year)
                     (list month 1 year)))))
      (persian-calendar--show-pmonth-at-edge
       (calendar-extract-month pdate)
       (calendar-extract-year pdate)
       arg))))

(defun persian-calendar--ad-other-month (orig month year &optional event)
  "Center the window on the Persian month containing Gregorian MONTH, YEAR.
ORIG is the advised function."
  (if (not (persian-calendar--active-p))
      (funcall orig month year event)
    (with-current-buffer (or (and (not event) (current-buffer))
                             (calendar-event-buffer event))
      (let* ((pdate (persian-calendar--from-gregorian (list month 15 year)))
             (pm (calendar-extract-month pdate))
             (py (calendar-extract-year pdate)))
        (unless (and (= pm displayed-month)
                     (= py displayed-year))
          (let ((old-date (calendar-cursor-to-date))
                (today (calendar-current-date)))
            (calendar-generate-window pm py)
            (calendar-cursor-to-visible-date
             (cond
              ((and old-date (calendar-date-is-visible-p old-date)) old-date)
              ((calendar-date-is-visible-p today) today)
              (t (persian-calendar--to-gregorian (list pm 1 py)))))
            (calendar-update-mode-line)))))))

(defun persian-calendar--ad-scroll-left (orig &optional arg event)
  "Scroll the Persian window left by ARG Persian months.
ORIG is the advised function."
  (if (not (persian-calendar--active-p))
      (funcall orig arg event)
    (unless arg (setq arg 1))
    (save-current-buffer
      (when (event-start event)
        (set-buffer (calendar-event-buffer event)))
      (calendar-cursor-to-nearest-date)
      (unless (zerop arg)
        (let* ((old-date (calendar-cursor-to-date))
               (today (calendar-current-date))
               (month displayed-month)
               (year displayed-year)
               (pold (persian-calendar--from-gregorian old-date))
               (offset (calendar-interval month year
                                          (calendar-extract-month pold)
                                          (calendar-extract-year pold))))
          (calendar-increment-month month year arg)
          (calendar-generate-window month year)
          (calendar-cursor-to-visible-date
           (cond
            ((calendar-date-is-visible-p old-date) old-date)
            ((calendar-date-is-visible-p today) today)
            (t (calendar-increment-month month year offset)
               (persian-calendar--to-gregorian (list month 1 year)))))))
      (run-hooks 'calendar-move-hook))))

(defun persian-calendar--ad-forward-month (orig arg)
  "Move the cursor forward ARG Persian months.
ORIG is the advised function."
  (if (not (persian-calendar--active-p))
      (funcall orig arg)
    (calendar-cursor-to-nearest-date)
    (let* ((pdate (persian-calendar--from-gregorian
                   (calendar-cursor-to-date t)))
           (month (calendar-extract-month pdate))
           (day (calendar-extract-day pdate))
           (year (calendar-extract-year pdate)))
      (calendar-increment-month month year arg)
      (setq day (min (calendar-persian-last-day-of-month month year) day))
      (let ((new-cursor-date (persian-calendar--to-gregorian
                              (list month day year))))
        (unless (calendar-date-is-visible-p new-cursor-date)
          (persian-calendar--show-pmonth-at-edge month year arg))
        (calendar-cursor-to-visible-date new-cursor-date)))
    (run-hooks 'calendar-move-hook)))

(defun persian-calendar--ad-beginning-of-month (orig arg)
  "Move the cursor backward ARG Persian month beginnings.
ORIG is the advised function."
  (if (not (persian-calendar--active-p))
      (funcall orig arg)
    (calendar-cursor-to-nearest-date)
    (let* ((pdate (persian-calendar--from-gregorian
                   (calendar-cursor-to-date)))
           (month (calendar-extract-month pdate))
           (day (calendar-extract-day pdate))
           (year (calendar-extract-year pdate)))
      (if (= day 1)
          (calendar-backward-month arg)
        (calendar-cursor-to-visible-date
         (persian-calendar--to-gregorian (list month 1 year)))
        (calendar-backward-month (1- arg))))))

(defun persian-calendar--ad-end-of-month (orig arg)
  "Move the cursor forward ARG Persian month ends.
ORIG is the advised function."
  (if (not (persian-calendar--active-p))
      (funcall orig arg)
    (calendar-cursor-to-nearest-date)
    (let* ((pdate (persian-calendar--from-gregorian
                   (calendar-cursor-to-date)))
           (month (calendar-extract-month pdate))
           (day (calendar-extract-day pdate))
           (year (calendar-extract-year pdate))
           (last-day (calendar-persian-last-day-of-month month year)))
      (unless (= day last-day)
        (calendar-cursor-to-visible-date
         (persian-calendar--to-gregorian (list month last-day year)))
        (setq arg (1- arg)))
      (calendar-increment-month month year arg)
      (let ((target (persian-calendar--to-gregorian
                     (list month
                           (calendar-persian-last-day-of-month month year)
                           year))))
        (unless (calendar-date-is-visible-p target)
          (persian-calendar--show-pmonth-at-edge month year arg))
        (calendar-cursor-to-visible-date target)))
    (run-hooks 'calendar-move-hook)))

(defun persian-calendar--ad-beginning-of-year (orig arg)
  "Move the cursor backward ARG Persian year beginnings.
ORIG is the advised function."
  (if (not (persian-calendar--active-p))
      (funcall orig arg)
    (calendar-cursor-to-nearest-date)
    (let* ((pdate (persian-calendar--from-gregorian
                   (calendar-cursor-to-date)))
           (month (calendar-extract-month pdate))
           (day (calendar-extract-day pdate))
           (year (calendar-extract-year pdate))
           (farvardin-first (persian-calendar--to-gregorian (list 1 1 year)))
           (calendar-move-hook nil))
      (if (and (= day 1) (= 1 month))
          (calendar-backward-month (* 12 arg))
        (if (and (= arg 1)
                 (calendar-date-is-visible-p farvardin-first))
            (calendar-cursor-to-visible-date farvardin-first)
          (setq year (- year (1- arg)))
          (persian-calendar--show-pmonth-at-edge 1 year (- arg))
          (calendar-cursor-to-visible-date
           (persian-calendar--to-gregorian (list 1 1 year))))))
    (run-hooks 'calendar-move-hook)))

(defun persian-calendar--ad-end-of-year (orig arg)
  "Move the cursor forward ARG Persian year ends.
ORIG is the advised function."
  (if (not (persian-calendar--active-p))
      (funcall orig arg)
    (calendar-cursor-to-nearest-date)
    (let* ((pdate (persian-calendar--from-gregorian
                   (calendar-cursor-to-date)))
           (month (calendar-extract-month pdate))
           (day (calendar-extract-day pdate))
           (year (calendar-extract-year pdate))
           (last-esfand (calendar-persian-last-day-of-month 12 year))
           (year-end (persian-calendar--to-gregorian
                      (list 12 last-esfand year)))
           (calendar-move-hook nil))
      (if (and (= day last-esfand) (= 12 month))
          (calendar-forward-month (* 12 arg))
        (if (and (= arg 1)
                 (calendar-date-is-visible-p year-end))
            (calendar-cursor-to-visible-date year-end)
          (setq year (+ year (1- arg)))
          (persian-calendar--show-pmonth-at-edge 12 year arg)
          (calendar-cursor-to-visible-date
           (persian-calendar--to-gregorian
            (list 12 (calendar-persian-last-day-of-month 12 year) year))))))
    (run-hooks 'calendar-move-hook)))

(defun persian-calendar--ad-recenter (orig)
  "Recenter the Persian window on the month of the date at point.
ORIG is the advised function."
  (if (not (persian-calendar--active-p))
      (funcall orig)
    (pcase-let ((positions '(center first last))
                (cursor-date (calendar-cursor-to-nearest-date))
                (`(,m1 ,y1 ,m2 ,y2) (calendar-get-month-range)))
      (setq calendar-recenter-last-op
            (if (eq this-command last-command)
                (car (or (cdr (memq calendar-recenter-last-op positions))
                         positions))
              (car positions)))
      (cond ((eq calendar-recenter-last-op 'center)
             (calendar-increment-month
              m1 y1 (/ (1- calendar-total-months) 2)))
            ((eq calendar-recenter-last-op 'first))
            ((eq calendar-recenter-last-op 'last)
             (setq m1 m2 y1 y2)))
      (let ((pcursor (persian-calendar--from-gregorian cursor-date)))
        (calendar-scroll-left
         (calendar-interval m1 y1
                            (calendar-extract-month pcursor)
                            (calendar-extract-year pcursor)))))))

(defun persian-calendar--ad-holidays-unsupported (orig &rest args)
  "Signal an error while the Persian display is active.
ORIG is the advised function and receives ARGS when the display is off."
  (if (persian-calendar--active-p)
      (user-error "Holidays are not supported in persian-calendar-mode")
    (apply orig args)))

(defun persian-calendar--ad-show-months-unsupported (orig &rest args)
  "Signal an error while the Persian display is active.
ORIG is the advised function and receives ARGS when the display is off."
  (if (persian-calendar--active-p)
      (user-error
       "Resizing the calendar is not supported in persian-calendar-mode")
    (apply orig args)))

;; Some advised functions are not yet defined at load time
;; (diary-lib's marking functions) and calendar--show-month-at-edge is
;; internal and 31.x-only; advice-add attaches to symbols regardless,
;; taking effect if and when the function is defined.
(defconst persian-calendar--advice-table
  '((calendar-persian-leap-year-p
     . persian-calendar--ad-persian-leap-year-p)
    (calendar-persian-to-absolute
     . persian-calendar--ad-persian-to-absolute)
    (calendar-persian-from-absolute
     . persian-calendar--ad-persian-from-absolute)
    (calendar-generate-window . persian-calendar--ad-generate-window)
    (calendar-generate . persian-calendar--ad-generate)
    (calendar-cursor-to-date . persian-calendar--ad-cursor-to-date)
    (calendar-cursor-to-visible-date
     . persian-calendar--ad-cursor-to-visible-date)
    (calendar-date-is-visible-p . persian-calendar--ad-date-is-visible-p)
    (calendar-mark-visible-date . persian-calendar--ad-mark-visible-date)
    (calendar-get-date-range . persian-calendar--ad-get-date-range)
    (calendar-mark-date-pattern . persian-calendar--ad-mark-date-pattern)
    (calendar-mark-days-named . persian-calendar--ad-mark-days-named)
    (calendar--show-month-at-edge . persian-calendar--ad-show-month-at-edge)
    (calendar-other-month . persian-calendar--ad-other-month)
    (calendar-scroll-left . persian-calendar--ad-scroll-left)
    (calendar-forward-month . persian-calendar--ad-forward-month)
    (calendar-beginning-of-month . persian-calendar--ad-beginning-of-month)
    (calendar-end-of-month . persian-calendar--ad-end-of-month)
    (calendar-beginning-of-year . persian-calendar--ad-beginning-of-year)
    (calendar-end-of-year . persian-calendar--ad-end-of-year)
    (calendar-recenter . persian-calendar--ad-recenter)
    (calendar-mark-holidays . persian-calendar--ad-holidays-unsupported)
    (calendar-list-holidays . persian-calendar--ad-holidays-unsupported)
    (calendar-show-more-months
     . persian-calendar--ad-show-months-unsupported)))

(defun persian-calendar--install-advice ()
  "Install all persian-calendar advice."
  (pcase-dolist (`(,sym . ,fn) persian-calendar--advice-table)
    (advice-add sym :around fn)))

(defun persian-calendar--remove-advice ()
  "Remove all persian-calendar advice."
  (pcase-dolist (`(,sym . ,fn) persian-calendar--advice-table)
    (advice-remove sym fn)))

;;;###autoload
(define-minor-mode persian-calendar-mode
  "Display the calendar grid using the Persian (Jalali) calendar.

While active, the three-month window shows Persian months with Farsi
names, the week starts on Saturday, and Friday is highlighted as the
weekend.  Dates returned to other commands remain Gregorian, so diary
and org integration keep working.  Toggling the mode off restores the
Gregorian grid at the cursor's date."
  :lighter " Persian"
  (unless (derived-mode-p 'calendar-mode)
    (setq persian-calendar-mode nil)
    (user-error "`persian-calendar-mode' only works in the calendar buffer"))
  (if persian-calendar-mode
      (let ((cursor-date (or (let ((persian-calendar-mode nil))
                               (calendar-cursor-to-nearest-date))
                             (calendar-current-date))))
        (setq-local calendar-week-start-day persian-calendar-week-start-day
                    calendar-weekend-days persian-calendar-weekend-days
                    calendar-intermonth-header nil
                    calendar-intermonth-text nil
                    bidi-paragraph-direction 'left-to-right)
        (setq calendar-mark-holidays nil)
        (let ((pdate (persian-calendar--from-gregorian cursor-date)))
          (calendar-generate-window (calendar-extract-month pdate)
                                    (calendar-extract-year pdate)))
        (calendar-cursor-to-visible-date cursor-date)
        (calendar-update-mode-line))
    (let ((cursor-date (or (let ((persian-calendar-mode t))
                             (calendar-cursor-to-nearest-date))
                           (calendar-current-date))))
      (kill-local-variable 'calendar-week-start-day)
      (kill-local-variable 'calendar-weekend-days)
      (kill-local-variable 'calendar-intermonth-header)
      (kill-local-variable 'calendar-intermonth-text)
      (kill-local-variable 'bidi-paragraph-direction)
      (setq calendar-mark-holidays calendar-mark-holidays-flag)
      (calendar-generate-window (calendar-extract-month cursor-date)
                                (calendar-extract-year cursor-date))
      (calendar-cursor-to-visible-date cursor-date)
      (calendar-update-mode-line))))

(defun persian-calendar--maybe-enable ()
  "Enable `persian-calendar-mode' if `persian-calendar-auto-enable' is set."
  (when (and persian-calendar-auto-enable
             (derived-mode-p 'calendar-mode)
             (not persian-calendar-mode))
    (persian-calendar-mode 1)))

(add-hook 'calendar-initial-window-hook #'persian-calendar--maybe-enable)

(persian-calendar--install-advice)

(defun persian-calendar-unload-function ()
  "Remove all advice and hooks installed by persian-calendar."
  (persian-calendar--remove-advice)
  (remove-hook 'calendar-initial-window-hook
               #'persian-calendar--maybe-enable)
  nil)

(provide 'persian-calendar)

;;; persian-calendar.el ends here
