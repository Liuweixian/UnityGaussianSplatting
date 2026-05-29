using UnityEngine;

public class RotatingObject : MonoBehaviour
{
    // Update is called once per frame
    void Update()
    {
        this.transform.Rotate(Vector3.up, 1f,Space.Self);
    }
}
