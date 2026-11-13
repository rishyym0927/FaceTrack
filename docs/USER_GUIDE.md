# Use FaceTrack

## Get the app and sign in

| Your role | Open in Chrome | On Android |
| --- | --- | --- |
| Student | [Student web app](https://facetrack.centralindia.cloudapp.azure.com/student/) | Install the signed **FaceTrack Student** APK from your project administrator. |
| Teacher or administrator | [Teacher web app](https://facetrack.centralindia.cloudapp.azure.com/teacher/) | Install the signed **FaceTrack Teacher** APK from your project administrator. |

Use the email and password provided by your administrator. Choose your institute if prompted. If you have multiple institute memberships, use the institute switcher to select the right one. Contact your administrator if you need an account, a password reset, or access to a missing subject.

To install on Android, open the APK from Downloads. If Android prompts you, allow installation from the app you opened it with, then tap **Install**. These signed builds use the hosted service over HTTPS and work without a USB cable or USB debugging. Install newer builds over the existing app. If Android reports a signing conflict, finish any pending recordings or uploads before asking the administrator how to replace the installed copy.

If you cloned the repository to run your own copy, follow the [installation guide](INSTALLATION.md). It lists the required tools, private configuration and model files.

## Student

1. Open **Subjects**. If your teacher already enrolled you, the subject appears there. Otherwise select **Join subject**, enter the teacher's code and wait for approval.
2. Open **Enrolment**. Read the consent notice and decide whether to continue. You can withdraw consent later from the same screen.
3. Tap **Record guided video** and follow the five directions. Keep your face in view and let the camera stop automatically, even if the directions finish early. The recorder runs for about 12–25 seconds and the saved video must contain at least 10 seconds.
4. Review the clip, then select **Upload for processing**. Keep the app open until the upload completes. After processing, faculty review the clip and approve or reject the enrolment.
5. Open **Attendance** to see your published records. For an incorrect published Absent mark, open the record and submit an attendance query.

## Teacher

1. Open an assigned subject from **Subjects**. Approve pending join requests and review face enrolments. In a face-enrolment review, play the clip and confirm the student's identity and each of the five poses before approving.
2. Open or create a session. New sessions include only students with subject approval and approved compatible face enrolment. See **Students → Pending face enrolment** for students who still need to complete that step. The app saves the eligible roster when you open the session. Classroom scanning requires two students on that roster with approved, compatible face enrolments. If the approvals came after the session opened, open a new session to include them.
3. Select **Scan classroom**, then **Start scan**. Keep only consenting participants in view. Move slowly and pause on each group. A green box means the face is well framed. Tap **Stop scan** when finished and keep the session open until uploads finish.
4. Select **Go to review**. Once usable footage is processed, matched students start as **Present** and the rest of the approved roster starts as **Absent**. Change any suggested mark before publishing. If no usable footage is available, enter the marks manually.
5. Select **Publish attendance**. In the session's **Reports** section, wait for the **Final report** to be ready, then select **Download PDF** or **Download CSV**. Refresh the session if the status stays queued.

## Administrator

Open **Admin** in the Teacher app using an account with an active admin membership. Create a semester term, add subjects and a class group, allocate each subject to its group, then create people and assign teachers. A class group uses a term, branch and semester. Faculty records use a full name and official email. Student records also require an enrolment number. See [first admin setup](INSTALLATION.md#56-make-the-first-admin-and-set-up-the-institute) for a new deployment.

## If something gets stuck

| What you see | What to do |
| --- | --- |
| Camera won't open | Allow camera access for the app or website, close any other app using it and try again. |
| Upload paused | Keep the screen open and select **Retry upload**. If the recording reservation expired, record again. |
| Face enrolment unavailable | Ask the project administrator to check the institute's model profile and processing worker. Reinstalling the app will not change server configuration. |
| Final report stays queued after refreshing | Ask the administrator to check the project's worker and its report permission. Include the session name and the time you published. |

Use the [camera validation guide](CAMERA_VALIDATION.md) for device checks and the [Azure runbook](DEPLOY_AZURE.md) for server operations.
